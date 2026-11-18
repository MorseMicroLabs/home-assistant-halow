#!/usr/bin/env bash
# The manager's liveness check of the status service: direct supervision with no network
# request. One check passes only if s6 reports the service up, the pid is the status
# server running as the status user, the recorded port is in LISTEN state on the bind
# address in the kernel's TCP table, and the server's liveness counter differs from the
# previous reading. The cases use fakes of s6-svstat, /proc/<pid> and /proc/net/tcp in
# the kernel's real formats, plus (at the end, off the target device) a real server
# process, the real /proc and real loopback listeners. Nothing here ran on the device.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh
. ./helpers_s6.sh

echo "== test_status_liveness =="

SERVER_REAL="$HALOW_LIB_DIR/status/status_server.py"
# Blocks that need a non-root user, loopback aliases or other facilities this machine may lack
# are skipped with a note; each skip is counted and printed in the summary line. A skipped
# block does not fail the suite (the checks of that block do not exist on such a machine),
# unless HALOW_REQUIRE_REAL_PROC=1 is set: then any skip is a failure (use it where the
# suite must be complete).
SKIPPED_BLOCKS=0
live_skip() { SKIPPED_BLOCKS=$((SKIPPED_BLOCKS + 1)); echo "  note: SKIPPED block: $1"; }
LIVE_PIDS=""
trap 'for p in $LIVE_PIDS; do kill -CONT "$p" 2>/dev/null; kill "$p" 2>/dev/null; done; [ -n "${HALOW_TEST_TMP:-}" ] && rm -rf -- "$HALOW_TEST_TMP"' EXIT

# --- the fake world --------------------------------------------------------------------

LIVE_UID="$(id -u)"
PORT=8099
HEXPORT="1FA3"          # 8099 in the kernel's table: four upper-case hex digits, big-endian
HEXADDR="01201EAC"      # 172.30.32.1: the bytes in memory order, so reversed in the table
LISTEN_LOCAL="${HEXADDR}:${HEXPORT}"
TCP_HEADER='  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode'

# The fake of s6-svstat prints what the real program printed (tests/fixtures): svstat_state
# <fixture state> [pid] for a service in that state, svstat_raw <text> [rc] for anything else.
svstat_state() { SVSTAT_MODE=fixture; SVSTAT_STATE="$1"; SVSTAT_PID="${2:-4300}"; s6_fixture_has "${1}_o" || { echo "no fixture state $1"; exit 2; }; }
svstat_raw() { SVSTAT_MODE=raw; SVSTAT_OUT="$1"; SVSTAT_RC="${2:-0}"; }
live_define_svstat() {
    s6-svstat() {
        local suffix=_plain
        printf 's6-svstat %s\n' "$*" >> "$CALLS"
        if [ "$SVSTAT_MODE" = raw ]; then
            if [ "$SVSTAT_RC" = 0 ]; then printf '%s\n' "$SVSTAT_OUT"; else printf '%s\n' "$SVSTAT_OUT" >&2; fi
            return "$SVSTAT_RC"
        fi
        if [ "${1:-} ${2:-}" = "-o up,pid" ]; then suffix=_o; fi
        s6_fixture_print "${SVSTAT_STATE}${suffix}" "$SVSTAT_PID"
    }
}
halow_test_setup >/dev/null 2>&1
LW_N=0
W=""
live_reset() {
    if [ -n "$W" ] && [ -d "$W" ]; then chmod -R u+rwx -- "$W" 2>/dev/null || :; rm -rf -- "$W"; fi
    LW_N=$((LW_N + 1))
    W="$HALOW_TEST_TMP/lw$LW_N"
    mkdir -p "$W/proc" "$W/hb"
    # a fresh manager process: its own counters, and the defaults of the limits
    HALOW_MGR_STATUS_FAILS=0; HALOW_MGR_STATUS_HB_PID=""; HALOW_MGR_STATUS_HB_LAST=""; HALOW_MGR_STATUS_WHY=""
    HALOW_MGR_STATUS_ELAPSED=0; HALOW_MGR_STATUS_FAILS_MAX=2; HALOW_MGR_STATUS_CHECK_S=30
    HALOW_MGR_TCP_TABLE_MAX_BYTES=1048576; HALOW_MGR_TCP_TABLE_MAX_LINES=8192; HALOW_MGR_HEARTBEAT_MAX_BYTES=32; HALOW_MGR_FILE_READ_TIMEOUT_S=1
    LOGF="$W/log"; CALLS="$W/calls"
    : > "$LOGF"; : > "$CALLS"
    export HALOW_PROC_DIR="$W/proc" HALOW_PROC_NET_TCP="$W/tcp" HALOW_STATUS_PORT_FILE="$W/status.port"
    export HALOW_STATUS_HEARTBEAT_FILE="$W/hb/heartbeat" HALOW_STATUS_BIND=172.30.32.1
    export HALOW_STATUS_USER="$(id -un)" HALOW_S6_STATUS_SERVICE_DIR=/run/service/status
    export HALOW_S6_SVSTAT=s6-svstat HALOW_S6_SVC=s6-svc
    unset HALOW_STATUS_SERVER
    SVC_RC=0
    svstat_state up 4300
    halow_log_info() { printf 'INFO %s\n' "$*" >> "$LOGF"; }
    halow_log_warning() { printf 'WARN %s\n' "$*" >> "$LOGF"; }
    halow_log_error() { printf 'ERROR %s\n' "$*" >> "$LOGF"; }
    halow_state_diag_set() { printf 'DIAG %s|%s\n' "$1" "$2" >> "$LOGF"; }
    live_define_svstat
    s6-svc() { printf 's6-svc %s\n' "$*" >> "$CALLS"; return "$SVC_RC"; }
    # Any network client the manager might reach for is a recorded failure.
    curl() { printf 'curl %s\n' "$*" >> "$CALLS"; return 1; }
    wget() { printf 'wget %s\n' "$*" >> "$CALLS"; return 1; }
    nc() { printf 'nc %s\n' "$*" >> "$CALLS"; return 1; }
    ncat() { printf 'ncat %s\n' "$*" >> "$CALLS"; return 1; }
    socat() { printf 'socat %s\n' "$*" >> "$CALLS"; return 1; }
    python3() { printf 'python3 %s\n' "$*" >> "$CALLS"; return 1; }
}

# live_proc <pid> <port> <uid> [<server path>] — a /proc/<pid> entry of the status server.
live_proc() {
    local pid="$1" port="$2" uid="$3" server="${4:-$HALOW_LIB_DIR/status/status_server.py}"
    mkdir -p "$HALOW_PROC_DIR/$pid"
    printf 'python3\0%s\0--port\0%s\0--bind\0172.30.32.1\0--allow-from\0172.30.32.2\0' "$server" "$port" > "$HALOW_PROC_DIR/$pid/cmdline"
    live_status_file "$pid" "$uid" "$uid"
}

# live_status_file <pid> <real uid> <effective uid> — /proc/<pid>/status as the kernel writes
# it (fields separated by tabs).
TAB=$'\t'
live_status_file() {
    {
        printf '%s\n' "Name:${TAB}python3" "Umask:${TAB}0022" "State:${TAB}S (sleeping)" "Pid:${TAB}$1"
        printf '%s\n' "Uid:${TAB}$2${TAB}$3${TAB}$2${TAB}$2" "Gid:${TAB}$2${TAB}$2${TAB}$2${TAB}$2"
    } > "$HALOW_PROC_DIR/$1/status"
}

# live_tcp_line <local> <remote> <state> <uid> — one line in the kernel's format.
LIVE_TCP_IDX=0
live_tcp_line() {
    LIVE_TCP_IDX=$((LIVE_TCP_IDX + 1))
    printf '%4d: %s %s %s 00000000:00000000 00:00000000 00000000 %5d        0 %d 1 0000000000000000 100 0 0 10 0\n' \
        "$LIVE_TCP_IDX" "$1" "$2" "$3" "$4" "$((20000 + LIVE_TCP_IDX))"
}

# live_tcp [lines...] — writes the table: the header, noise, then the given lines.
live_tcp() {
    LIVE_TCP_IDX=0
    {
        printf '%s\n' "$TCP_HEADER"
        live_tcp_line 0100007F:0035 00000000:0000 0A 0
        live_tcp_line 00000000:0016 00000000:0000 0A 0
        local l
        for l in "$@"; do printf '%s\n' "$l"; done
        live_tcp_line 0B01A8C0:C350 0A01A8C0:01BB 01 1000
    } > "$HALOW_PROC_NET_TCP"
}

live_hb() { mkdir -p "$W/hb"; printf '%s\n' "$1" > "$HALOW_STATUS_HEARTBEAT_FILE"; }

# live_world — a healthy status service: s6 up as pid 4300, its process entry, the port
# file, a LISTEN line owned by the status user, and a counter of 100.
live_world() {
    svstat_state up 4300
    live_proc 4300 "$PORT" "$LIVE_UID"
    printf '%s\n' "$PORT" > "$HALOW_STATUS_PORT_FILE"
    live_tcp "$(live_tcp_line "$LISTEN_LOCAL" 00000000:0000 0A "$LIVE_UID")"
    live_hb 100
}

live_check() { _halow_mgr_status_check; }
live_warns() { grep -c '^WARN ' "$LOGF" || true; }
live_last_warn() { grep '^WARN ' "$LOGF" | tail -n 1 || true; }
live_svc_calls() { grep -c '^s6-svc ' "$CALLS" || true; }
live_net_calls() { grep -c -E '^(curl|wget|nc|ncat|socat|python3) ' "$CALLS" || true; }
live_log_has() { grep -qF -- "$1" "$LOGF"; }
live_log_lacks() { ! grep -qF -- "$1" "$LOGF"; }

# live_expect_fail <description> <reason fragment> — one check that must fail with that reason
# and count as one failure (no restart after a single failure).
live_expect_fail() {
    local before after
    before="$(live_warns)"
    live_check
    after="$(live_warns)"
    assert_eq "$((before + 1))" "$after" "$1: one failed check is logged"
    assert_success "$1: the reason is '$2'" bash -c 'case "$1" in *"$2"*) exit 0 ;; esac; exit 1' _ "$(live_last_warn)" "$2"
    assert_eq "1" "$HALOW_MGR_STATUS_FAILS" "$1: counted as one consecutive failure"
    assert_eq "0" "$(live_svc_calls)" "$1: a single failure never restarts the service"
}

# live_healthy <description> — one check that must pass (no new warning, count at zero).
live_healthy() {
    local before after
    before="$(live_warns)"
    live_check
    after="$(live_warns)"
    assert_eq "$before" "$after" "$1: no warning"
    assert_eq "0" "$HALOW_MGR_STATUS_FAILS" "$1: failure count is zero"
}

# =======================================================================================
echo "-- the check makes no network request (static) --"
MGR="$HALOW_LIB_DIR/manager.sh"
status_code="$(awk '/^# --- Status-service liveness/ {p = 1} p && /^# _halow_mgr_hostapd_cli / {exit} p {print}' "$MGR")"
assert_success "the status liveness code was found (the check below can fail)" test "$(wc -l <<< "$status_code")" -gt 80
code_only="$(sed -E 's/^[[:space:]]*#.*$//' <<< "$status_code")"
for pat in 'curl' 'wget' '/dev/tcp' '/dev/udp' 'HALOW_CURL' 'ncat' 'socat' 'telnet' 'python3' '172\.30\.32\.2' 'ALLOW_FROM'; do
    assert_failure "the status liveness code never uses '$pat'" grep -qE -- "(^|[^A-Za-z0-9_-])${pat}" <<< "$code_only"
done
assert_failure "no command in the status liveness code is called ' nc '" grep -qE '(^|[;&|(]|then|do)[[:space:]]*nc[[:space:]]' <<< "$code_only"
assert_failure "the manager as a whole no longer reads HALOW_CURL" grep -q 'HALOW_CURL' "$MGR"
assert_success "the control: the manager still names s6-svstat and the TCP table" bash -c 'grep -q HALOW_S6_SVSTAT "$0" && grep -q HALOW_PROC_NET_TCP "$0"' "$MGR"

# =======================================================================================
echo "-- a healthy service: baseline, then a changing counter --"
live_reset; live_world
live_healthy "first reading (baseline)"
live_hb 101
live_healthy "counter changed"
live_hb 105
live_healthy "counter changed again"
assert_eq "0" "$(live_warns)" "no warning at all in a healthy run"
assert_eq "0" "$(live_svc_calls)" "never restarted"
assert_eq "0" "$(live_net_calls)" "no network client was ever called"
assert_eq "3" "$(grep -c '^s6-svstat -o up,pid /run/service/status$' "$CALLS")" "s6-svstat asked about the status service directory once per check"
assert_eq "172.30.32.2" "${HALOW_STATUS_ALLOW_FROM:-}" "the peer allow value in the environment is the Ingress proxy's address and untouched"

# =======================================================================================
echo "-- an unchanged counter: bounded restart, exactly FAILS_MAX consecutive failures --"
live_reset; live_world
live_check                              # baseline 100
live_check                              # same value: failure 1
assert_eq "1" "$HALOW_MGR_STATUS_FAILS" "unchanged once: one failure"
assert_eq "0" "$(live_svc_calls)" "no restart after one failure"
assert_success "the log line keeps its text and names the reason" live_log_has "manager: the status service did not answer (1 of 2): the liveness counter is not advancing"
live_check                              # failure 2
assert_eq "1" "$(live_svc_calls)" "the second consecutive failure asks s6 to restart exactly once"
assert_eq "s6-svc -r /run/service/status" "$(grep '^s6-svc ' "$CALLS")" "with the same command as before"
assert_eq "0" "$HALOW_MGR_STATUS_FAILS" "the failure count restarts from zero after the request"
assert_success "the restart is logged as before" live_log_has "WARN manager: the status service was asked to restart"
assert_success "the diagnostic key is unchanged" live_log_has "DIAG status_service|restarted after not answering"
assert_eq "" "$HALOW_MGR_STATUS_HB_LAST$HALOW_MGR_STATUS_HB_PID" "the counter baseline is forgotten with the restart request"
live_check                              # same pid still, same value, but baseline gone: new baseline
assert_eq "0" "$HALOW_MGR_STATUS_FAILS" "right after a restart request the next reading is a new baseline, not a failure"
live_check
assert_eq "1" "$HALOW_MGR_STATUS_FAILS" "an unchanged counter after that counts again from one"
assert_eq "1" "$(live_svc_calls)" "still a single restart request (no restart on one failure)"

echo "-- one failure then recovery: the count returns to zero, no restart --"
live_reset; live_world
live_check; live_check
assert_eq "1" "$HALOW_MGR_STATUS_FAILS" "one unchanged reading"
live_hb 101
live_check
assert_eq "0" "$HALOW_MGR_STATUS_FAILS" "an advancing counter clears the failure count"
live_check
assert_eq "1" "$HALOW_MGR_STATUS_FAILS" "failures need to be consecutive to add up"
live_hb 102; live_check
assert_eq "0" "$(live_svc_calls)" "alternating failures and recoveries never restart the service"

echo "-- a failing restart request --"
live_reset; live_world; SVC_RC=1
live_check; live_check; live_check
assert_success "the failed request is logged as an error" live_log_has "ERROR manager: the status service could not be asked to restart"
assert_success "and recorded in the diagnostics" live_log_has "DIAG status_service|not answering; restart request failed"
assert_eq "0" "$HALOW_MGR_STATUS_FAILS" "the count restarts after a failed request too (a bounded retry, not one per check)"
assert_eq "1" "$(live_svc_calls)" "one request"

echo "-- FAILS_MAX is honoured --"
live_reset; live_world; HALOW_MGR_STATUS_FAILS_MAX=3
live_check; live_check; live_check
assert_eq "0" "$(live_svc_calls)" "with 3 as the limit, two failures do not restart"
live_check
assert_eq "1" "$(live_svc_calls)" "the third consecutive failure does"
live_reset; live_world; HALOW_MGR_STATUS_FAILS_MAX=1
live_check; live_check
assert_eq "1" "$(live_svc_calls)" "with 1 as the limit the first failure restarts"

echo "-- a counter that starts again counts as changed (different, not greater) --"
live_reset; live_world
live_hb 5000; live_check
live_hb 3; live_check
assert_eq "0" "$HALOW_MGR_STATUS_FAILS" "a lower value with the same pid is a change"
live_hb 3; live_check
assert_eq "1" "$HALOW_MGR_STATUS_FAILS" "the same value is not"
live_hb 99999999999999999999; live_check
assert_eq "0" "$HALOW_MGR_STATUS_FAILS" "a 20-digit value is accepted and a change"

echo "-- the status service restarts by itself: a new pid and a counter that starts again --"
live_reset; live_world
live_hb 40; live_check
live_hb 41; live_check
svstat_state up 4400; live_proc 4400 "$PORT" "$LIVE_UID"; live_hb 1
live_healthy "new pid, counter back at 1: a new baseline"
live_hb 1; live_check
assert_eq "1" "$HALOW_MGR_STATUS_FAILS" "after the baseline, the same value is unchanged again"
live_reset; live_world
live_hb 7; live_check
svstat_state up 4400; live_proc 4400 "$PORT" "$LIVE_UID"; live_hb 7
live_healthy "a new pid with the same value is a baseline, not 'unchanged' (the old process's value is not the new process's)"

echo "-- the stale counter of an earlier run cannot satisfy the check --"
live_reset; live_world
live_hb 200; live_check                  # baseline of the previous process
svstat_state up 4401; live_proc 4401 "$PORT" "$LIVE_UID"   # the new process has not written yet: still 200
live_check                               # baseline (new pid)
live_check                               # still 200: unchanged
live_check
assert_eq "1" "$(live_svc_calls)" "a new process that never advances the old value is restarted after the usual two failures"

echo "-- a manager restart: the first reading is a baseline --"
live_reset; live_world
live_check; live_check
assert_eq "1" "$HALOW_MGR_STATUS_FAILS" "an unchanged counter is on its way to a restart"
# a new manager process starts: it loads the library again, which initialises its state
# (nothing is reset by hand here)
. "$HALOW_LIB_DIR/manager.sh"
assert_eq "0" "$HALOW_MGR_STATUS_FAILS" "a new manager process starts with a zero failure count"
assert_eq "" "$HALOW_MGR_STATUS_HB_PID$HALOW_MGR_STATUS_HB_LAST" "...and with no counter baseline"
live_define_svstat
live_healthy "the same value read by a new manager is a baseline"
live_check
assert_eq "1" "$HALOW_MGR_STATUS_FAILS" "...and it is judged again from there (unchanged, one failure)"

# =======================================================================================
echo "-- s6 state --"
for st in never_started unsupervised_early missing killed stopped; do
    live_reset; live_world; svstat_state "$st" 4300
    live_expect_fail "the real s6-svstat output for a service in state '$st' (rc $(s6_fixture_rc "${st}_o"))" "the service is not running"
    assert_success "...and the log has no s6 text" live_log_lacks "s6-supervise"
done
for case_ in "" "true" "true 0" "true -1" "true abc" "true 4300 extra" "true  4300" " true 4300" "true 4300 " "TRUE 4300" "true 12345678901" "false 4300" "up" "false -1" \
             "up (pid 4300) 100 seconds" "up (pid 47 pgid 47) 2 seconds" "up (pid 4300 pgid 4300) 100 seconds, want down" "s6-svstat: fatal: unable to read status for /run/service/status: s6-supervise not running"; do
    live_reset; live_world; svstat_raw "$case_"
    live_expect_fail "s6 prints '$case_'" "the service is not running"
done
live_reset; live_world; svstat_raw "true 4300" 1
live_expect_fail "s6-svstat exits non-zero even with a valid-looking line" "the service is not running"
live_reset; live_world; svstat_raw $'true 4300\ntrue 4301'
live_expect_fail "two lines" "the service is not running"
live_reset; live_world
live_check
assert_eq "s6-svstat -o up,pid /run/service/status" "$(grep '^s6-svstat' "$CALLS" | head -n 1)" "the manager asks for the machine-readable form, for the status service directory"
assert_eq "true 4300" "$(s6_fixture_print up_o 4300)" "(control) the fixture's up_o output is 'true <pid>'"
assert_failure "(control) the human-readable form of the real output is not what the manager parses" bash -c '[[ "$(s6_fixture_out up_plain)" =~ ^true\ ]]'
live_reset; live_world; svstat_state up 4300; SVSTAT_STATE=up
assert_eq "up (pid 4300 pgid 4300) 2 seconds" "$(s6_fixture_print up_plain 4300 | sed 's/pid 47 pgid 47/pid 4300 pgid 4300/')" "(control) the real plain form has 'pgid N' after the pid"
live_reset; live_world; HALOW_S6_SVSTAT=/nonexistent/s6-svstat
live_expect_fail "s6-svstat not found" "the service is not running"
for st in up want_down normally_down_up; do
    live_reset; live_world; svstat_state "$st" 4300
    live_healthy "the real s6-svstat output for a service in state '$st'"
done

echo "-- process identity (pid reuse, wrong program, wrong port, wrong user) --"
live_reset; live_world; rm -rf "$HALOW_PROC_DIR/4300"
live_expect_fail "no such process" "the running process is not the status server"
live_reset; live_world; printf 'sleep\0100\0' > "$HALOW_PROC_DIR/4300/cmdline"
live_expect_fail "pid reused by another program" "the running process is not the status server"
live_reset; live_world; live_proc 4300 "$PORT" "$LIVE_UID" /usr/bin/other_server.py
live_expect_fail "another program with the status server's options" "the running process is not the status server"
live_reset; live_world; live_proc 4300 "$PORT" "$LIVE_UID" "$HALOW_LIB_DIR/status/status_server.py.bak"
live_expect_fail "a longer name (not a whole argument match)" "the running process is not the status server"
live_reset; live_world; printf 'python3\0%s\0' "$HALOW_LIB_DIR/status/status_server.py" > "$HALOW_PROC_DIR/4300/cmdline"
live_expect_fail "no --port argument" "the running process is not the status server"
live_reset; live_world; live_proc 4300 9999 "$LIVE_UID"
live_expect_fail "serving another port than the recorded one" "the running process is not the status server"
live_reset; live_world; printf 'python3\0%s\0--port=%s\0' "$HALOW_LIB_DIR/status/status_server.py" "$PORT" > "$HALOW_PROC_DIR/4300/cmdline"
live_expect_fail "--port=N (the launcher never writes that form)" "the running process is not the status server"
live_reset; live_world; printf 'python3\0%s\0%s\0--port\0' "$HALOW_LIB_DIR/status/status_server.py" "$PORT" > "$HALOW_PROC_DIR/4300/cmdline"
live_expect_fail "the port number does not follow --port" "the running process is not the status server"
live_reset; live_world; live_proc 4300 "$PORT" 0
if [ "$LIVE_UID" != 0 ]; then
    live_expect_fail "the process runs as root" "the running process is not the status server"
else
    live_skip "running as root; the 'process runs as root' case is the same as the expected user and was SKIPPED"
fi
live_reset; live_world; live_proc 4300 "$PORT" "$((LIVE_UID + 1))"
live_expect_fail "the process runs as another user" "the running process is not the status server"
live_reset; live_world; live_status_file 4300 "$LIVE_UID" 0
live_expect_fail "real uid right, effective uid root" "the running process is not the status server"
live_reset; live_world; printf '%s\n' "Name:${TAB}python3" > "$HALOW_PROC_DIR/4300/status"
live_expect_fail "no Uid line" "the running process is not the status server"
live_reset; live_world; rm -f "$HALOW_PROC_DIR/4300/status"
live_expect_fail "the status file of the process is missing" "the running process is not the status server"
live_reset; live_world; rm -f "$HALOW_PROC_DIR/4300/cmdline"
live_expect_fail "the command line of the process is missing" "the running process is not the status server"
live_reset; live_world; HALOW_STATUS_USER="no-such-user-xyz"
live_expect_fail "the status user does not exist" "the status user is unknown"
live_reset; live_world; HALOW_STATUS_SERVER=/opt/elsewhere/status_server.py
live_expect_fail "a server path other than the one launched" "the running process is not the status server"
live_reset; live_world; live_proc 4300 "$PORT" "$LIVE_UID" /opt/elsewhere/status_server.py; HALOW_STATUS_SERVER=/opt/elsewhere/status_server.py
live_healthy "the server path can be redirected (tests), and then matches"
live_reset; live_world
if [ "$LIVE_UID" != 0 ]; then
    chmod 000 "$HALOW_PROC_DIR/4300/cmdline"
    live_expect_fail "the command line cannot be read" "the running process is not the status server"
else
    live_skip "running as root; the unreadable command line case was SKIPPED"
fi

echo "-- the recorded port --"
for content in "" "abc" "80a" "0" "65536" "99999" "123456" "-1" "+80" "8 099" " 8099" "8099 " "0x1F90" "8099;x" "8099 junk" "TOPSECRETPORTVALUE"; do
    live_reset; live_world; printf '%s\n' "$content" > "$HALOW_STATUS_PORT_FILE"
    live_expect_fail "port file holds '$content'" "the recorded port is missing or invalid"
done
live_reset; live_world; rm -f "$HALOW_STATUS_PORT_FILE"
live_expect_fail "no port file" "the recorded port is missing or invalid"
live_reset; live_world; rm -f "$HALOW_STATUS_PORT_FILE"; mkdir "$HALOW_STATUS_PORT_FILE"
live_expect_fail "the port file is a directory" "the recorded port is missing or invalid"
live_reset; live_world; printf '%s\n' "$PORT" > "$W/real.port"; rm -f "$HALOW_STATUS_PORT_FILE"; ln -s "$W/real.port" "$HALOW_STATUS_PORT_FILE"
live_expect_fail "the port file is a symbolic link" "the recorded port is missing or invalid"
live_reset; live_world; head -c 100000 /dev/zero | tr '\0' '8' > "$HALOW_STATUS_PORT_FILE"
live_expect_fail "an oversized port file" "the recorded port is missing or invalid"
live_reset; live_world; printf '%s' "$PORT" > "$HALOW_STATUS_PORT_FILE"
live_healthy "a port file without a newline"
live_reset; live_world; printf '08099\n' > "$HALOW_STATUS_PORT_FILE"
live_healthy "a port file with leading zeros is read as the same number"
live_reset; live_world; chmod 000 "$HALOW_STATUS_PORT_FILE"
if [ "$LIVE_UID" != 0 ]; then
    live_expect_fail "the port file cannot be read" "the recorded port is missing or invalid"
else
    live_skip "running as root; the unreadable port file case was SKIPPED"
fi

# =======================================================================================
echo "-- the kernel's TCP table --"
live_reset; live_world
assert_eq "01201EAC" "$(_halow_mgr_ipv4_hex 172.30.32.1)" "172.30.32.1 is 01201EAC in the table (little-endian address)"
assert_eq "0200007F" "$(_halow_mgr_ipv4_hex 127.0.0.2)" "127.0.0.2 is 0200007F"
assert_eq "0100007F" "$(_halow_mgr_ipv4_hex 127.0.0.1)" "127.0.0.1 is 0100007F"
assert_eq "00000000" "$(_halow_mgr_ipv4_hex 0.0.0.0)" "0.0.0.0 is 00000000"
for bad in "" "::1" "172.30.32" "172.30.32.256" "172.30.32.1.5" "a.b.c.d" "172.30.32.-1" "172.30.32.1 " " 172.30.32.1"; do
    assert_failure "'$bad' is not an IPv4 bind address" _halow_mgr_ipv4_hex "$bad"
done
assert_eq "1FA3" "$(printf '%04X' 8099)" "8099 is 1FA3 (big-endian port, four digits)"

LISTEN_OK="$(live_tcp_line "$LISTEN_LOCAL" 00000000:0000 0A "$LIVE_UID")"
tcp_case() {   # tcp_case <description> <expect: ok|fail> <lines...>
    local desc="$1" expect="$2"; shift 2
    live_reset; live_world
    live_tcp "$@"
    if [ "$expect" = ok ]; then
        live_healthy "$desc"
    else
        live_expect_fail "$desc" "the port is not listening on the expected address"
    fi
}
tcp_case "the listener" ok "$LISTEN_OK"
tcp_case "the listener after other sockets" ok "$(live_tcp_line 0100007F:1F90 00000000:0000 0A 0)" "$(live_tcp_line 0B01A8C0:0050 00000000:0000 0A 0)" "$LISTEN_OK"
tcp_case "no socket on the port at all" fail
tcp_case "listening on another port" fail "$(live_tcp_line "${HEXADDR}:1FA4" 00000000:0000 0A "$LIVE_UID")"
tcp_case "port in little-endian (A31F)" fail "$(live_tcp_line "${HEXADDR}:A31F" 00000000:0000 0A "$LIVE_UID")"
tcp_case "address in big-endian (AC1E2001)" fail "$(live_tcp_line "AC1E2001:${HEXPORT}" 00000000:0000 0A "$LIVE_UID")"
tcp_case "listening on the wildcard address" fail "$(live_tcp_line "00000000:${HEXPORT}" 00000000:0000 0A "$LIVE_UID")"
tcp_case "listening on loopback" fail "$(live_tcp_line "0100007F:${HEXPORT}" 00000000:0000 0A "$LIVE_UID")"
tcp_case "listening on the Ingress proxy address" fail "$(live_tcp_line "02201EAC:${HEXPORT}" 00000000:0000 0A "$LIVE_UID")"
for st in 01 02 03 04 05 06 07 08 09 0B 00 FF; do
    tcp_case "state $st instead of LISTEN" fail "$(live_tcp_line "$LISTEN_LOCAL" 00000000:0000 "$st" "$LIVE_UID")"
done
tcp_case "an established connection on the port is not a listener" fail "$(live_tcp_line "$LISTEN_LOCAL" 02201EAC:9C40 01 "$LIVE_UID")"
tcp_case "a listener with a remote address (not a listening socket)" fail "$(live_tcp_line "$LISTEN_LOCAL" 02201EAC:9C40 0A "$LIVE_UID")"
tcp_case "established connections beside the listener do not disturb it" ok "$LISTEN_OK" "$(live_tcp_line "$LISTEN_LOCAL" 02201EAC:9C40 01 "$LIVE_UID")" "$(live_tcp_line "$LISTEN_LOCAL" 02201EAC:9C41 06 0)"
tcp_case "lower-case hex is not the kernel's format" fail "$(live_tcp_line "${HEXADDR,,}:${HEXPORT,,}" 00000000:0000 0a "$LIVE_UID")"
tcp_case "a listener owned by another user" fail "$(live_tcp_line "$LISTEN_LOCAL" 00000000:0000 0A "$((LIVE_UID + 1))")"
tcp_case "a listener owned by root while the status user is not root" "$([ "$LIVE_UID" = 0 ] && echo ok || echo fail)" "$(live_tcp_line "$LISTEN_LOCAL" 00000000:0000 0A 0)"
tcp_case "two listeners on the same address and port are ambiguous" fail "$LISTEN_OK" "$LISTEN_OK"
tcp_case "two listeners, one of them foreign, are ambiguous" fail "$LISTEN_OK" "$(live_tcp_line "$LISTEN_LOCAL" 00000000:0000 0A "$((LIVE_UID + 1))")"
tcp_case "a line cut after the state" fail "   9: ${LISTEN_LOCAL} 00000000:0000 0A"
tcp_case "a line cut inside the uid" fail "   9: ${LISTEN_LOCAL} 00000000:0000 0A 00000000:00000000 00:00000000 00000000"
tcp_case "a line cut in the address" fail "   9: ${HEXADDR}:1F"
tcp_case "garbage lines around the listener" ok "this is not a table line" "!!!" "$LISTEN_OK" ":::::" ""
tcp_case "the listener line without an index" fail "${LISTEN_LOCAL} 00000000:0000 0A 00000000:00000000 00:00000000 00000000 ${LIVE_UID} 0 20 1 0 100 0 0 10 0"
tcp_case "non-numeric uid" fail "   9: ${LISTEN_LOCAL} 00000000:0000 0A 00000000:00000000 00:00000000 00000000 abc 0 20 1 0 100 0 0 10 0"
tcp_case "a negative uid" fail "   9: ${LISTEN_LOCAL} 00000000:0000 0A 00000000:00000000 00:00000000 00000000 -1 0 20 1 0 100 0 0 10 0"
tcp_case "binary garbage in the table" fail "$(printf '\001\002\003 \377\376')"

live_reset; live_world; : > "$HALOW_PROC_NET_TCP"
live_expect_fail "an empty table" "the port is not listening on the expected address"
live_reset; live_world; printf '%s\n' "$TCP_HEADER" > "$HALOW_PROC_NET_TCP"
live_expect_fail "a table with only its header" "the port is not listening on the expected address"
live_reset; live_world; rm -f "$HALOW_PROC_NET_TCP"
live_expect_fail "no table" "the port is not listening on the expected address"
live_reset; live_world; rm -f "$HALOW_PROC_NET_TCP"; mkdir "$HALOW_PROC_NET_TCP"
live_expect_fail "the table is a directory" "the port is not listening on the expected address"
live_reset; live_world
if [ "$LIVE_UID" != 0 ]; then
    chmod 000 "$HALOW_PROC_NET_TCP"
    live_expect_fail "the table cannot be read" "the port is not listening on the expected address"
else
    live_skip "running as root; the unreadable table case was SKIPPED"
fi
for b in "::1" "172.30.32" "300.1.1.1"; do
    live_reset; live_world; HALOW_STATUS_BIND="$b"
    live_expect_fail "bind address '$b' is not IPv4" "the port is not listening on the expected address"
done
live_reset; live_world; HALOW_STATUS_BIND=127.0.0.2; live_proc 4300 "$PORT" "$LIVE_UID"
live_tcp "$(live_tcp_line "0200007F:${HEXPORT}" 00000000:0000 0A "$LIVE_UID")"
live_healthy "the bind address comes from HALOW_STATUS_BIND"
# The IPv6 table is never consulted: a listener only in a tcp6 table does not count.
live_reset; live_world; live_tcp; printf '%s\n' "$TCP_HEADER" "   0: 0000000000000000FFFF000001201EAC:${HEXPORT} 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000 ${LIVE_UID} 0 1 1 0 100 0 0 10 0" > "$W/tcp6"
live_expect_fail "a listener that appears only in a tcp6 table" "the port is not listening on the expected address"

echo "-- the table is read with bounds --"
live_reset; live_world
big="$W/bigtcp"
awk -v want="$LISTEN_LOCAL" -v hdr="$TCP_HEADER" -v uid="$LIVE_UID" 'BEGIN {
    print hdr
    printf "%4d: %s 00000000:0000 0A 00000000:00000000 00:00000000 00000000 %5d        0 1 1 0000000000000000 100 0 0 10 0\n", 0, want, uid
    for (i = 1; i < 300000; i++) printf "%4d: 0B01A8C0:%04X 0A01A8C0:01BB 01 00000000:00000000 00:00000000 00000000  1000        0 %d 1 0000000000000000 100 0 0 10 0\n", i, (i % 60000) + 1024, i + 100
}' > "$big"
assert_success "the large table was built (over 30 MB; the control for the cases below)" test "$(stat -c %s "$big")" -gt 30000000
cp "$big" "$HALOW_PROC_NET_TCP"
start=$SECONDS
live_healthy "a table of 300000 lines with the listener first (listeners come first in the kernel's table)"
assert_success "...checked in bounded time (under 20 s)" test "$((SECONDS - start))" -lt 20
{ printf '%s\n' "$TCP_HEADER"; tail -n +3 "$big" | head -n 20000; live_tcp_line "$LISTEN_LOCAL" 00000000:0000 0A "$LIVE_UID"; } > "$HALOW_PROC_NET_TCP"
live_expect_fail "the listener beyond the first 8192 lines is not read" "the port is not listening on the expected address"
live_reset; live_world; HALOW_MGR_TCP_TABLE_MAX_LINES=10
{ printf '%s\n' "$TCP_HEADER"; for _i in 1 2 3 4 5 6 7 8 9; do live_tcp_line 0B01A8C0:0050 00000000:0000 06 0; done; live_tcp_line "$LISTEN_LOCAL" 00000000:0000 0A "$LIVE_UID"; live_tcp_line 0B01A8C0:0051 00000000:0000 06 0; } > "$HALOW_PROC_NET_TCP"
live_expect_fail "with a limit of 10 lines, a listener on line 11 is outside" "the port is not listening on the expected address"
live_reset; live_world; HALOW_MGR_TCP_TABLE_MAX_LINES=10
{ printf '%s\n' "$TCP_HEADER"; for _i in 1 2 3; do live_tcp_line 0B01A8C0:0050 00000000:0000 06 0; done; live_tcp_line "$LISTEN_LOCAL" 00000000:0000 0A "$LIVE_UID"; } > "$HALOW_PROC_NET_TCP"
live_healthy "with a limit of 10 lines, a listener on line 5 is read"
live_reset; live_world; HALOW_MGR_TCP_TABLE_MAX_BYTES=600
{ printf '%s\n' "$TCP_HEADER"; for _i in 1 2 3 4 5 6; do live_tcp_line 0B01A8C0:0050 00000000:0000 06 0; done; live_tcp_line "$LISTEN_LOCAL" 00000000:0000 0A "$LIVE_UID"; } > "$HALOW_PROC_NET_TCP"
live_expect_fail "with a limit of 600 bytes, a listener beyond the 600th byte is not read" "the port is not listening on the expected address"
live_reset; live_world; HALOW_MGR_TCP_TABLE_MAX_BYTES=600
{ printf '%s\n' "$TCP_HEADER"; live_tcp_line "$LISTEN_LOCAL" 00000000:0000 0A "$LIVE_UID"; } > "$HALOW_PROC_NET_TCP"
live_healthy "with a limit of 600 bytes, a listener within them is read"
live_reset; live_world; head -c 3000000 /dev/zero | tr '\0' 'x' > "$HALOW_PROC_NET_TCP"
start=$SECONDS
live_expect_fail "3 MB without a single newline" "the port is not listening on the expected address"
assert_success "...also bounded in time" test "$((SECONDS - start))" -lt 20

# =======================================================================================
echo "-- the liveness counter file --"
hb_case() {   # hb_case <description> <printf format for the file content> [args]
    local desc="$1"; shift
    live_reset; live_world
    live_check                               # baseline from a valid file
    printf -- "$@" > "$HALOW_STATUS_HEARTBEAT_FILE"
    live_expect_fail "$desc" "the liveness counter is missing or invalid"
}
hb_case "an empty counter file" ''
hb_case "only a newline" '\n'
hb_case "letters" 'abc\n'
hb_case "digits then letters" '123abc\n'
hb_case "letters then digits" 'abc123\n'
hb_case "a negative number" '-5\n'
hb_case "a signed number" '+5\n'
hb_case "a decimal number" '5.5\n'
hb_case "a hexadecimal number" '0x10\n'
hb_case "an exponent" '1e5\n'
hb_case "leading space" ' 5\n'
hb_case "trailing space" '5 \n'
hb_case "two numbers" '5 6\n'
hb_case "two lines" '5\n6\n'
hb_case "an extra newline" '5\n\n'
hb_case "a carriage return" '5\r\n'
hb_case "21 digits" '%s\n' 123456789012345678901
hb_case "32 digits" '%s\n' 12345678901234567890123456789012
hb_case "a long line of digits" '%s\n' "$(head -c 5000 /dev/zero | tr '\0' '7')"
hb_case "a valid number followed by padding that makes the file oversized" '5\n%s' "$(head -c 40 /dev/zero | tr '\0' ' ')"
hb_case "a secret-looking text" 'TOPSECRETHEARTBEATTEXT\n'
hb_case "a leading NUL byte and text" '\0abc\n'
hb_case "unicode digits" '\xd9\xa5\n'

live_reset; live_world; live_check; rm -f "$HALOW_STATUS_HEARTBEAT_FILE"
live_expect_fail "a missing counter file" "the liveness counter is missing or invalid"
live_reset; live_world; live_check; rm -f "$HALOW_STATUS_HEARTBEAT_FILE"; mkdir "$HALOW_STATUS_HEARTBEAT_FILE"
live_expect_fail "the counter path is a directory" "the liveness counter is missing or invalid"
live_reset; live_world; live_check; rm -rf "$W/hb"
live_expect_fail "the whole directory is missing" "the liveness counter is missing or invalid"
live_reset; live_world; live_check; printf '101\n' > "$W/other"; rm -f "$HALOW_STATUS_HEARTBEAT_FILE"; ln -s "$W/other" "$HALOW_STATUS_HEARTBEAT_FILE"
live_expect_fail "the counter file is a symbolic link" "the liveness counter is missing or invalid"
live_reset; live_world; live_check
if [ "$LIVE_UID" != 0 ]; then
    chmod 000 "$HALOW_STATUS_HEARTBEAT_FILE"
    live_expect_fail "an unreadable counter file" "the liveness counter is missing or invalid"
    live_reset; live_world; live_check; chmod 000 "$W/hb"
    live_expect_fail "an unreadable counter directory" "the liveness counter is missing or invalid"
    chmod 700 "$W/hb"
else
    live_skip "running as root; the unreadable counter cases were SKIPPED"
fi
live_reset; live_world; live_check; printf '100' > "$HALOW_STATUS_HEARTBEAT_FILE"
live_expect_fail "a counter without a final newline is accepted and, unchanged, is a failure of 'not advancing' (not of validity)" "not advancing"
live_reset; live_world; live_check; printf '101' > "$HALOW_STATUS_HEARTBEAT_FILE"
live_healthy "a changed counter without a final newline"
live_reset; live_world; live_check; printf '12345678901234567890\n' > "$HALOW_STATUS_HEARTBEAT_FILE"
live_healthy "the longest accepted value (20 digits)"
live_reset; live_world; live_check; printf '007\n' > "$HALOW_STATUS_HEARTBEAT_FILE"
live_healthy "leading zeros are digits; only a difference counts"

echo "-- the counter is read with a bound --"
live_reset; live_world; live_check; HALOW_MGR_HEARTBEAT_MAX_BYTES=8
printf '123456789' > "$HALOW_STATUS_HEARTBEAT_FILE"
live_expect_fail "with a limit of 8 bytes, a 9-byte file is oversized" "the liveness counter is missing or invalid"
live_reset; live_world; live_check; HALOW_MGR_HEARTBEAT_MAX_BYTES=8
printf '12345678\n' > "$HALOW_STATUS_HEARTBEAT_FILE"
live_expect_fail "with a limit of 8 bytes, 8 digits and a newline (9 bytes) are oversized" "the liveness counter is missing or invalid"
live_reset; live_world; live_check; HALOW_MGR_HEARTBEAT_MAX_BYTES=8
printf '1234567\n' > "$HALOW_STATUS_HEARTBEAT_FILE"
live_healthy "with a limit of 8 bytes, 7 digits and a newline (8 bytes) are read"
live_reset; live_world; live_check; HALOW_MGR_HEARTBEAT_MAX_BYTES=8
printf '12345678' > "$HALOW_STATUS_HEARTBEAT_FILE"
live_healthy "with a limit of 8 bytes, 8 digits without a newline are read"
live_reset; live_world; live_check
head -c 60000000 /dev/zero | tr '\0' '5' > "$HALOW_STATUS_HEARTBEAT_FILE"
start=$SECONDS
live_expect_fail "a 60 MB counter file" "the liveness counter is missing or invalid"
assert_success "...rejected without reading it all (under 5 s)" test "$((SECONDS - start))" -lt 5

echo "-- a read failure resets the baseline: recovery is a new baseline, never 'unchanged' --"
live_reset; live_world; live_check
printf 'junk\n' > "$HALOW_STATUS_HEARTBEAT_FILE"; live_check
assert_eq "1" "$HALOW_MGR_STATUS_FAILS" "one invalid reading"
live_hb 100; live_check
assert_eq "0" "$HALOW_MGR_STATUS_FAILS" "the same value as before the failure is a fresh baseline"
live_check
assert_eq "1" "$HALOW_MGR_STATUS_FAILS" "and is then unchanged"

# =======================================================================================
echo "-- several different failures in a row count together and restart once --"
live_reset; live_world
live_check
svstat_state stopped 4300; live_check
assert_success "first: not running" live_log_has "(1 of 2): the service is not running"
printf 'zzz\n' > "$HALOW_STATUS_PORT_FILE"; svstat_state up 4300; live_check
assert_success "second: port invalid" live_log_has "(2 of 2): the recorded port is missing or invalid"
assert_eq "1" "$(live_svc_calls)" "two different consecutive failures restart once"

echo "-- no secrets and no counter values in any log line --"
live_reset; live_world
VAL1=7391846205; VAL2=7391846999; VAL3=7391847123
live_hb "$VAL1"; live_check        # baseline
live_hb "$VAL2"; live_check        # a change: the healthy path
live_hb "$VAL3"; live_check        # a change again
assert_eq "0" "$HALOW_MGR_STATUS_FAILS" "the healthy path was taken three times (baseline, change, change)"
assert_eq "0" "$(live_warns)" "...and it logged nothing"
assert_success "...not even at the level of information" live_log_lacks "INFO "
live_hb "$VAL3"; live_check        # now the failing paths
live_hb "$VAL3"; live_check
live_hb "$VAL3"; live_check
printf 'TOPSECRETHEARTBEATTEXT-%s\n' "$VAL1" > "$HALOW_STATUS_HEARTBEAT_FILE"; live_check
printf 'TOPSECRETPORTTEXT\n' > "$HALOW_STATUS_PORT_FILE"; live_check
live_reset_log_keep="$(cat "$LOGF")"
assert_success "the log has lines to inspect (the check can fail)" test -n "$live_reset_log_keep"
for needle in "$VAL1" "$VAL2" "$VAL3" "TOPSECRET" "$HALOW_STATUS_HEARTBEAT_FILE" "$HALOW_STATUS_PORT_FILE" "7391846"; do
    assert_success "the log never contains '$needle'" live_log_lacks "$needle"
done
assert_failure "no line of the log is anything but a fixed manager message" bash -c 'grep -vE "^(WARN|ERROR|INFO|DIAG) (manager: the status service|status_service\|)" "$0"' "$LOGF"

# =======================================================================================
echo "-- the shipped defaults (a fresh shell, no environment) --"
defaults="$(env -i bash -c '. "$1/constants.sh"; . "$1/manager.sh"; printf "%s " "$HALOW_MGR_HEARTBEAT_MAX_BYTES" "$HALOW_MGR_TCP_TABLE_MAX_LINES" "$HALOW_MGR_TCP_TABLE_MAX_BYTES" "$HALOW_MGR_STATUS_CHECK_S" "$HALOW_MGR_STATUS_FAILS_MAX" "$HALOW_MGR_FILE_READ_TIMEOUT_S" "$HALOW_S6_SVSTAT" "$HALOW_PROC_NET_TCP" "$HALOW_STATUS_BIND" "$HALOW_STATUS_ALLOW_FROM" "$HALOW_STATUS_HEARTBEAT_FILE"' _ "$HALOW_LIB_DIR")"
assert_eq "32 8192 1048576 30 2 2 s6-svstat /proc/net/tcp 172.30.32.1 172.30.32.2 /run/halow-status/heartbeat " "$defaults" "counter 32 bytes, table 8192 lines and 1 MiB, check every 30 s, 2 failures, 2 s read limit, s6-svstat, /proc/net/tcp, bind 172.30.32.1, allowed peer 172.30.32.2 only, counter /run/halow-status/heartbeat"

# =======================================================================================
echo "-- the bounded, time-limited reader (a FIFO in place of a file must not hang the manager) --"
live_reset; live_world
rb_start=$SECONDS
mkfifo "$W/fifo"
_halow_mgr_read_bounded "$W/fifo" 33; rb_rc=$?
assert_eq "1" "$rb_rc" "a FIFO nobody writes to: the read fails"
assert_success "...within a few seconds (not blocked for ever)" test "$((SECONDS - rb_start))" -le 6
printf 'abc\n\n' > "$W/plain"
_halow_mgr_read_bounded "$W/plain" 33
assert_eq "$(printf 'abc\n\nx')" "${HALOW_MGR_READ_DATA}x" "a regular file is returned exactly (trailing newlines kept)"
printf '0123456789\n' > "$W/ten"
_halow_mgr_read_bounded "$W/ten" 4
assert_eq "0123" "$HALOW_MGR_READ_DATA" "at most the given number of bytes is returned"
head -c 5000000 /dev/zero | tr '\0' '7' > "$W/huge"
rb_start=$SECONDS
_halow_mgr_read_bounded "$W/huge" 33
assert_eq "33" "${#HALOW_MGR_READ_DATA}" "a 5 MB file: 33 bytes read"
assert_success "...at once" test "$((SECONDS - rb_start))" -le 3
assert_failure "a missing file fails" _halow_mgr_read_bounded "$W/none" 33
assert_failure "a directory fails" _halow_mgr_read_bounded "$W" 33
assert_eq "" "$HALOW_MGR_READ_DATA" "a failed read leaves no data behind"
assert_failure "a read that does not finish in time fails" bash -c '. "$1/manager.sh"; HALOW_MGR_FILE_READ_TIMEOUT_S=1; HALOW_TIMEOUT_CMD=timeout; _halow_mgr_read_bounded "$2" 33' _ "$HALOW_LIB_DIR" "$W/fifo"

echo "-- a FIFO, a swapped file, a directory or a link in place of the counter or the port file --"
for target in heartbeat port; do
    if [ "$target" = heartbeat ]; then F="$HALOW_STATUS_HEARTBEAT_FILE"; FN=_halow_mgr_status_heartbeat; else F="$HALOW_STATUS_PORT_FILE"; FN=_halow_mgr_status_port; fi
    live_reset; live_world
    if [ "$target" = heartbeat ]; then F="$HALOW_STATUS_HEARTBEAT_FILE"; FN=_halow_mgr_status_heartbeat; else F="$HALOW_STATUS_PORT_FILE"; FN=_halow_mgr_status_port; fi
    live_check
    rm -f "$F"; mkfifo "$F"
    fs=$SECONDS
    live_expect_fail "the $target file is a FIFO with no writer" "missing or invalid"
    assert_success "...and the check returned within a few seconds" test "$((SECONDS - fs))" -le 8
    # a FIFO with a writer that offers perfectly valid content is still not a regular file
    ( printf '55\n' > "$F" ) &
    wpid=$!
    assert_failure "the $target file is a FIFO with a writer offering valid content: refused by its type" "$FN"
    kill "$wpid" 2>/dev/null; cat "$F" > /dev/null 2>&1 & cpid=$!; sleep 0.2; kill "$cpid" 2>/dev/null; wait 2>/dev/null
    rm -f "$F"; mkdir "$F"
    assert_failure "the $target path is a directory" "$FN"
    rmdir "$F"; printf '55\n' > "$W/elsewhere"; ln -s "$W/elsewhere" "$F"
    assert_failure "the $target path is a symbolic link to a valid file" "$FN"
    rm -f "$F"; printf '55\n' > "$F"
    assert_success "control: a regular file with the same content is accepted" "$FN"
done

live_reset; live_world
HALOW_MGR_STATUS_CHECK_S=30; HALOW_MGR_STATUS_ELAPSED=0
_halow_mgr_status_tick 10; _halow_mgr_status_tick 10
assert_eq "0" "$(grep -c '^s6-svstat' "$CALLS")" "no check before 30 s of supervise time"
_halow_mgr_status_tick 10
assert_eq "1" "$(grep -c '^s6-svstat' "$CALLS")" "a check at 30 s"
assert_eq "0" "$HALOW_MGR_STATUS_ELAPSED" "the elapsed time restarts"
_halow_mgr_status_tick 30
assert_eq "2" "$(grep -c '^s6-svstat' "$CALLS")" "and again 30 s later"
assert_eq "0" "$(live_net_calls)" "no network client was called"

echo "-- under the add-on's strict shell options --"
live_reset; live_world
out="$(set -o errexit -o errtrace -o nounset -o pipefail; shopt -s inherit_errexit
       live_check; live_hb 101; live_check; live_hb 101; live_check; live_check; live_check
       printf 'rc=ok svc=%s fails=%s\n' "$(live_svc_calls)" "$HALOW_MGR_STATUS_FAILS")"
assert_eq "rc=ok svc=1 fails=0" "$out" "every path returns 0 under errexit, nounset and pipefail (a restart request after two failures)"
live_reset; live_world; rm -f "$HALOW_STATUS_HEARTBEAT_FILE" "$HALOW_PROC_NET_TCP" "$HALOW_STATUS_PORT_FILE"; rm -rf "$HALOW_PROC_DIR/4300"
out="$(set -o errexit -o errtrace -o nounset -o pipefail; shopt -s inherit_errexit; svstat_state missing 4300
       live_check; live_check; live_check; printf 'rc=ok svc=%s\n' "$(live_svc_calls)")"
assert_eq "rc=ok svc=1" "$out" "a world without any state files still returns 0 under strict options"

# =======================================================================================
echo "-- a real server process, the real /proc and real loopback sockets (off the target device) --"
if [ "$LIVE_UID" = 0 ]; then
    live_skip "running as root; the status server refuses to run as root, so the real-process checks were SKIPPED"
elif ! env python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.2", 0))' 2>/dev/null; then
    live_skip "127.0.0.2 cannot be bound here; the real-process checks were SKIPPED"
else
    live_reset
    unset -f python3 s6-svstat s6-svc curl wget nc ncat socat
    live_define_svstat
    s6-svc() { printf 's6-svc %s\n' "$*" >> "$CALLS"; return 0; }
    curl() { printf 'curl %s\n' "$*" >> "$CALLS"; return 1; }
    RP="$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.2", 0)); print(s.getsockname()[1]); s.close()')"
    export HALOW_PROC_DIR=/proc HALOW_PROC_NET_TCP=/proc/net/tcp HALOW_STATUS_BIND=127.0.0.2
    export HALOW_STATUS_SERVER="$SERVER_REAL" HALOW_STATUS_HEARTBEAT_FILE="$W/hb/heartbeat"
    printf '%s\n' "$RP" > "$HALOW_STATUS_PORT_FILE"
    printf '{"schema":1}\n' > "$W/snap.json"
    chmod 700 "$W/hb"
    python3 -I "$SERVER_REAL" --port "$RP" --bind 127.0.0.2 --allow-from 127.0.0.9 --snapshot "$W/snap.json" \
        --heartbeat-file "$HALOW_STATUS_HEARTBEAT_FILE" --heartbeat-interval 0.3 > "$W/server.out" 2> "$W/server.err" &
    SPID=$!
    LIVE_PIDS="$LIVE_PIDS $SPID"
    for _i in $(seq 1 60); do [ -s "$HALOW_STATUS_HEARTBEAT_FILE" ] && grep -q listening "$W/server.err" && break; sleep 0.1; done
    svstat_state up "$SPID"
    assert_success "the real server wrote its counter" test -s "$HALOW_STATUS_HEARTBEAT_FILE"
    assert_eq "600" "$(stat -c %a "$HALOW_STATUS_HEARTBEAT_FILE")" "the real counter file is mode 0600"
    live_healthy "real server, real /proc, real TCP table: baseline"
    sleep 1
    live_healthy "real server: the counter advanced"
    assert_success "the real TCP table lists the real listener (the table reader worked on the kernel's own format)" _halow_mgr_status_listening "$RP" "$LIVE_UID"
    assert_failure "...and not on another port" _halow_mgr_status_listening "$((RP + 1))" "$LIVE_UID"
    assert_failure "...and not for another owner" _halow_mgr_status_listening "$RP" "$((LIVE_UID + 1))"
    HALOW_STATUS_BIND=127.0.0.1
    assert_failure "...and not on another address (127.0.0.1)" _halow_mgr_status_listening "$RP" "$LIVE_UID"
    HALOW_STATUS_BIND=127.0.0.2
    # A different process under the same pid slot: a plain sleeping process.
    sleep 300 &
    OPID=$!
    LIVE_PIDS="$LIVE_PIDS $OPID"
    svstat_state up "$OPID"
    live_expect_fail "s6 names a live process that is not the status server (pid reuse)" "the running process is not the status server"
    svstat_state up "$SPID"; HALOW_MGR_STATUS_FAILS=0
    live_check
    # The server hangs: the counter stops, the listener and the process stay.
    kill -STOP "$SPID"
    sleep 0.8
    live_check                      # may still see the last value written before the stop: baseline or change
    HALOW_MGR_STATUS_FAILS=0
    sleep 1
    live_check                      # unchanged: failure 1
    assert_eq "1" "$HALOW_MGR_STATUS_FAILS" "a stopped server: the first unchanged reading is failure 1"
    assert_success "the stopped server still holds the listening socket (so only the counter shows the hang)" _halow_mgr_status_listening "$RP" "$LIVE_UID"
    sleep 0.5
    live_check                      # failure 2: restart request
    assert_eq "1" "$(live_svc_calls)" "a hung server is restarted after two unchanged readings"
    assert_eq "0" "$(grep -c '^curl ' "$CALLS")" "the manager made no network request to the server"
    kill -CONT "$SPID"
    sleep 1
    live_check
    assert_eq "0" "$HALOW_MGR_STATUS_FAILS" "after the process runs again, the next reading is a new baseline"
    : > "$CALLS"    # the restart request above is accounted for; count again from here
    # The server stops being the process s6 names.
    kill "$SPID" 2>/dev/null; wait "$SPID" 2>/dev/null
    svstat_state stopped "$SPID"
    live_expect_fail "the server is gone" "the service is not running"
    svstat_state up "$SPID"; HALOW_MGR_STATUS_FAILS=0
    live_expect_fail "s6 still names the dead pid" "the running process is not the status server"
    # A listener that is not the status server holds the port.
    python3 -I -c 'import socket, sys, time
s = socket.socket(); s.bind(("127.0.0.2", int(sys.argv[1]))); s.listen(5); time.sleep(120)' "$RP" &
    LPID=$!
    LIVE_PIDS="$LIVE_PIDS $LPID"
    sleep 0.5
    assert_success "a listener on the right address and port owned by the same user is accepted by the table reader (the process identity check is what rules this one out)" \
        _halow_mgr_status_listening "$RP" "$LIVE_UID"
    svstat_state up "$LPID"; HALOW_MGR_STATUS_FAILS=0
    live_expect_fail "that process is not the status server" "the running process is not the status server"
    kill "$LPID" 2>/dev/null; wait "$LPID" 2>/dev/null
    python3 -I -c 'import socket, sys, time
s = socket.socket(); s.bind(("0.0.0.0", int(sys.argv[1]))); s.listen(5); time.sleep(120)' "$RP" &
    LPID=$!
    LIVE_PIDS="$LIVE_PIDS $LPID"
    sleep 0.5
    assert_failure "a wildcard listener is not on the bind address" _halow_mgr_status_listening "$RP" "$LIVE_UID"
    kill "$LPID" 2>/dev/null; wait "$LPID" 2>/dev/null
    assert_failure "after it is gone nothing listens" _halow_mgr_status_listening "$RP" "$LIVE_UID"
    kill "$OPID" 2>/dev/null; wait "$OPID" 2>/dev/null
fi

if [ "${HALOW_REQUIRE_REAL_PROC:-0}" = "1" ] && [ "$SKIPPED_BLOCKS" -gt 0 ]; then
    HALOW_TEST_COUNT=$((HALOW_TEST_COUNT + 1)); HALOW_TEST_FAILURES=$((HALOW_TEST_FAILURES + 1))
    echo "  FAIL: HALOW_REQUIRE_REAL_PROC=1 and $SKIPPED_BLOCKS block(s) were skipped"
fi
echo "test_status_liveness: $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed, $SKIPPED_BLOCKS skipped blocks"
exit $([ "$HALOW_TEST_FAILURES" -eq 0 ] && echo 0 || echo 1)
