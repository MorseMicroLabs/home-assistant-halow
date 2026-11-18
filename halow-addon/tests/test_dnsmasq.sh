#!/usr/bin/env bash
# Tests DHCP/DNS on the bridge (rootfs/usr/lib/halow/dnsmasq.sh) with a fake `dnsmasq`
# that is a real process named dnsmasq (tests/doubles/bin/dnsmasq), so the add-on's real
# /proc identity checks run unchanged: configuration contents, files only in the run
# directory, ownership before creation, refusal to adopt an unowned instance, stop and
# confirmation, bounded restarts, and the port-conflict check.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh
. ./doubles/fakes_env.sh

halow_test_setup
halow_fakes_install
mkdir -p "$HALOW_RUN_DIR"
SLEEPS="$HALOW_TEST_TMP/sleeps"; : > "$SLEEPS"
halow_dnsmasq_sleep() { echo "$1" >> "$SLEEPS"; command sleep 0.3; }
_now=1000
halow_dnsmasq_now() { printf '%s' "$_now"; }
CONF="$HALOW_RUN_DIR/dnsmasq.conf"; PIDF="$HALOW_RUN_DIR/dnsmasq.pid"; LEASES="$HALOW_LEASE_DIR/dnsmasq.leases"

live_fakes() { # pids of live fake dnsmasq processes using our run-directory configuration
    local d pid out=""
    for d in /proc/[0-9]*; do
        pid="${d#/proc/}"
        [ "$(cat "$d/comm" 2>/dev/null)" = "dnsmasq" ] || continue
        if tr '\0' '\n' < "$d/cmdline" 2>/dev/null | grep -qxF -- "--conf-file=$CONF"; then out="$out $pid"; fi
    done
    printf '%s' "${out# }"
}
cleanup_fakes() { local p; for p in $(live_fakes); do kill "$p" 2>/dev/null; done; command sleep 0.3; }

echo "== test_dnsmasq: paths =="
assert_eq "$HALOW_LEASE_DIR/dnsmasq.leases" "$(halow_dhcp_lease_file)" "the lease file is in the persistent lease directory (under /data in the product)"
assert_eq "false" "$([ "$HALOW_LEASE_DIR" = "$HALOW_STATE_DIR" ] || [ "$HALOW_LEASE_DIR" = "$HALOW_RUN_DIR" ] && echo true || echo false)" "...which is neither the state directory (reconcile clears that) nor the run directory (tmpfs)"
assert_eq "$HALOW_RUN_DIR/dnsmasq.conf" "$(halow_dnsmasq_conf_file)" "the configuration is in the run directory"
assert_eq "$HALOW_RUN_DIR/dnsmasq.pid" "$(halow_dnsmasq_pid_file)" "the pid file is in the run directory"

echo "== test_dnsmasq: start =="
_order="$HALOW_TEST_TMP/order"; : > "$_order"
eval "$(declare -f halow_own_mark | sed '1s/halow_own_mark/_real_own_mark/')"
halow_own_mark() { [ "$1" != net_dnsmasq ] || { [ -e "$CONF" ] && echo conf-before-marker >> "$_order" || echo marker-first >> "$_order"; }; _real_own_mark "$@"; }
assert_success "dnsmasq starts on the bridge" halow_dnsmasq_start halow-br0 192.168.90.1 192.168.90.50 192.168.90.150 12h
unset -f halow_own_mark; eval "$(declare -f _real_own_mark | sed '1s/_real_own_mark/halow_own_mark/')"
assert_eq "marker-first" "$(cat "$_order")" "the ownership marker is written before the configuration file"
assert_success "net_dnsmasq is owned" halow_own_check net_dnsmasq
assert_eq "interface=halow-br0
except-interface=lo
bind-interfaces
listen-address=192.168.90.1
dhcp-range=192.168.90.50,192.168.90.150,12h
dhcp-option=3,192.168.90.1
dhcp-option=6,192.168.90.1
dhcp-ignore-names
quiet-dhcp
dhcp-leasefile=$LEASES" "$(cat "$CONF")" "the configuration binds the bridge only (never loopback), serves DNS on the gateway, and ignores client host names, and keeps leases in the persistent lease directory"
assert_success "the dnsmasq command line names the run-directory configuration and pid file" \
    grep -qxF "dnsmasq --conf-file=$CONF --pid-file=$PIDF --no-daemon" "$HALOW_FAKE_LOG"
_pid="$(cat "$PIDF")"
assert_eq "$_pid" "$(live_fakes)" "exactly one instance is running and its pid is recorded"
assert_success "halow_dnsmasq_running recognises it by identity" halow_dnsmasq_running
assert_file_absent "$HALOW_STATE_DIR/dnsmasq.conf" "no configuration file in the persistent state directory"
assert_file_absent "$HALOW_STATE_DIR/dnsmasq.leases" "no lease file in the persistent state directory"
assert_file_absent "$HALOW_STATE_DIR/dnsmasq.pid" "no pid file in the persistent state directory"
assert_success "a second start is idempotent" halow_dnsmasq_start halow-br0 192.168.90.1 192.168.90.50 192.168.90.150 12h
assert_eq "$_pid" "$(live_fakes)" "...and starts no second instance"
assert_eq "1" "$(grep -c '^dnsmasq ' "$HALOW_FAKE_LOG")" "...dnsmasq was executed once"

echo "== test_dnsmasq: stop =="
echo "1700000000 aa:bb:cc:00:00:01 192.168.90.51 dev1 *" > "$LEASES"
assert_success "stop succeeds" halow_dnsmasq_stop
assert_eq "" "$(live_fakes)" "the process is gone"
assert_file_absent "$CONF" "the configuration is removed"
assert_file_absent "$PIDF" "the pid file is removed"
assert_file_exists "$LEASES" "the lease file is kept (an add-on restart must not forget the leases)"
assert_eq "1700000000 aa:bb:cc:00:00:01 192.168.90.51 dev1 *" "$(cat "$LEASES")" "...unchanged"
assert_failure "the marker is cleared" halow_own_check net_dnsmasq
assert_success "stopping again is idempotent" halow_dnsmasq_stop

echo "== test_dnsmasq: DHCP leases survive an add-on restart =="
# The fake dnsmasq does not read the lease file; what is proved here is the product's own
# plumbing (where the file lives, what is kept across stop and start, what is discarded
# before dnsmasq sees it, and that nothing expires a lease by hand). That the REAL dnsmasq
# honours a persisted file is proved by test_dnsmasq_real.sh.
DM_ARGS=(halow-br0 192.168.90.1 192.168.90.50 192.168.90.150 12h)
cat > "$LEASES" <<'EOF'
5000 02:00:00:00:00:11 192.168.90.51 laptop 01:02:00:00:00:00:11
900 02:00:00:00:00:12 192.168.90.52 expired *
0 02:00:00:00:00:13 192.168.90.53 forever *
5000 02:00:00:00:00:14 192.168.91.60 outside-the-range *
this is not a lease line
5000 zz:00:00:00:00:15 192.168.90.55 bad-mac *
5000 02:00:00:00:00:16 192.168.90.300 bad-ip *
5000 02:00:00:00:00:17 192.168.90.56 first *
5000 02:00:00:00:00:18 192.168.90.56 second *
5000 02:00:00:00:00:19 192.168.90.57 host * extra-field
duid 00:01:00:01:aa:bb:cc:dd:ee:ff:00:11:22:33
EOF
assert_success "start with a persisted file" halow_dnsmasq_start "${DM_ARGS[@]}"
assert_eq "5000 02:00:00:00:00:11 192.168.90.51 * 01:02:00:00:00:00:11
0 02:00:00:00:00:13 192.168.90.53 * *
5000 02:00:00:00:00:17 192.168.90.56 * *" "$(cat "$LEASES")" "kept: well-formed, unexpired (or infinite), in range, first claim of an address; dropped: expired, out of range, malformed, duplicate address, other record types; host names removed"
assert_eq "700" "$(stat -c %a "$HALOW_LEASE_DIR")" "the lease directory is private (0700)"
assert_eq "600" "$(stat -c %a "$LEASES")" "the lease file is private (0600)"
assert_eq "0" "$(grep -c "laptop\|expired\|forever" "$LEASES")" "no client host name is kept"
assert_success "the configuration names the persisted file" grep -qxF "dhcp-leasefile=$LEASES" "$CONF"
assert_success "...and tells dnsmasq to ignore client-supplied names" grep -qxF "dhcp-ignore-names" "$CONF"
assert_success "...and not to log routine DHCP transactions (routine transactions, with client MAC and IP, stay out of the add-on log; errors still appear)" grep -qxF "quiet-dhcp" "$CONF"
assert_success "stop (an ordinary add-on restart)" halow_dnsmasq_stop
assert_eq "3" "$(wc -l < "$LEASES" | tr -d ' ')" "the leases are still there after the stop"
_now=6000
assert_success "start again later (the clock has passed the 5000 expiries)" halow_dnsmasq_start "${DM_ARGS[@]}"
assert_eq "0 02:00:00:00:00:13 192.168.90.53 * *" "$(cat "$LEASES")" "expired leases are not revived; an infinite lease stays; nothing was extended"
assert_success "stop" halow_dnsmasq_stop
_now=1000

echo "== test_dnsmasq: the preparation's bounds and its temporary file =="
printf '%s\n' "5000 02:00:00:00:00:51 192.168.90.71 h1 *" "5000 02:00:00:00:00:52 192.168.90.72 h2 *" \
    "5000 02:00:00:00:00:53 192.168.90.73 h3 *" "5000 02:00:00:00:00:54 192.168.90.74 h4 *" > "$LEASES"
: > "$HALOW_LEASE_DIR/.dnsmasq.leases.abcdef"
HALOW_LEASE_MAX_LINES=2 _halow_dnsmasq_prepare_leases 192.168.90.50 192.168.90.150 > "$HALOW_TEST_TMP/prep.log" 2>&1
assert_eq "2" "$(wc -l < "$LEASES" | tr -d ' ')" "lines beyond the line limit are not kept"
assert_success "...and their number is logged (a count, never an address)" grep -q "kept 2 persisted DHCP lease(s), dropped 2 " "$HALOW_TEST_TMP/prep.log"
assert_eq "0" "$(grep -c '192.168\|02:00' "$HALOW_TEST_TMP/prep.log")" "...the log line names no address"
assert_eq "dnsmasq.leases" "$(ls -A "$HALOW_LEASE_DIR")" "no temporary file is left in the lease directory, a stale one from an earlier run is removed"
assert_eq "5000 02:00:00:00:00:51 192.168.90.71 * *" "$(head -n 1 "$LEASES")" "a host name is rewritten to * (the first kept line shows it)"
rm -f "$LEASES"; HALOW_DNSMASQ_LEASE_ACTIVE=""

echo "== test_dnsmasq: a damaged persisted lease file never blocks the start =="
head -c 3000 /dev/urandom > "$LEASES"
assert_success "binary garbage: dnsmasq still starts" halow_dnsmasq_start "${DM_ARGS[@]}"
assert_eq "0" "$(grep -c . "$LEASES")" "...and the file holds no garbage line (valid or empty)"
halow_dnsmasq_stop
echo "5000 02:00:00:00:00:11 192.168.90.51 laptop *" > "$LEASES"
HALOW_LEASE_MAX_BYTES=10 halow_dnsmasq_start "${DM_ARGS[@]}"
assert_eq "0" "$(wc -c < "$LEASES" | tr -d ' ')" "an oversized file is discarded, not parsed"
halow_dnsmasq_stop
rm -f "$LEASES"; echo "5000 02:00:00:00:00:11 192.168.90.51 laptop *" > "$HALOW_TEST_TMP/elsewhere"; ln -s "$HALOW_TEST_TMP/elsewhere" "$LEASES"
assert_success "a symbolic link in place of the file: still starts" halow_dnsmasq_start "${DM_ARGS[@]}"
assert_success "...and the link is replaced by a regular file" test -f "$LEASES" -a ! -L "$LEASES"
assert_eq "5000 02:00:00:00:00:11 192.168.90.51 laptop *" "$(cat "$HALOW_TEST_TMP/elsewhere")" "...without touching what it pointed at"
halow_dnsmasq_stop
rm -f "$LEASES"; mkdir "$LEASES"
assert_success "a directory in place of the file: still starts" halow_dnsmasq_start "${DM_ARGS[@]}"
assert_success "...and a regular file takes its place" test -f "$LEASES"
halow_dnsmasq_stop
halow_dnsmasq_stop
: > "$HALOW_TEST_TMP/not-a-dir"
_saved_leasedir="$HALOW_LEASE_DIR"; HALOW_LEASE_DIR="$HALOW_TEST_TMP/not-a-dir"
assert_success "a lease directory that cannot be used: still starts" halow_dnsmasq_start "${DM_ARGS[@]}"
assert_eq "$HALOW_RUN_DIR/dnsmasq.leases" "$(halow_dhcp_lease_file)" "...with the volatile run-directory file as the lease file"
assert_success "...and dnsmasq is configured with it" grep -qxF "dhcp-leasefile=$HALOW_RUN_DIR/dnsmasq.leases" "$CONF"
echo "5000 02:00:00:00:00:11 192.168.90.51 * *" > "$HALOW_RUN_DIR/dnsmasq.leases"
halow_dnsmasq_stop
assert_file_absent "$HALOW_RUN_DIR/dnsmasq.leases" "the volatile fallback file is removed at stop"
HALOW_LEASE_DIR="$_saved_leasedir"; HALOW_DNSMASQ_LEASE_ACTIVE=""
assert_eq "$LEASES" "$(halow_dhcp_lease_file)" "a usable directory again: the persisted path is used"

echo "== test_dnsmasq: the volatile fallback is found and removed from a FRESH process =="
# The s6 finish hook, a rollback and a new manager are separate processes: none of them has
# HALOW_DNSMASQ_LEASE_ACTIVE. Every check below runs the later step in `env -i bash -c`.
FB="$HALOW_RUN_DIR/dnsmasq.leases"
fresh() { # <shell snippet> — a new process with only the durable environment
    env -i PATH="$PATH" HALOW_STATE_DIR="$HALOW_STATE_DIR" HALOW_RUN_DIR="$HALOW_RUN_DIR" \
        HALOW_LEASE_DIR="$HALOW_LEASE_DIR" HALOW_FAKE_LOG="$HALOW_FAKE_LOG" HALOW_LIB_DIR="$HALOW_LIB_DIR" \
        bash -c 'for lib in constants common ownership validate iface_detect network_backend dnsmasq; do . "$HALOW_LIB_DIR/$lib.sh"; done
                 halow_dnsmasq_sleep() { command sleep 0.3; }
                 '"$1"
}
GOOD_LEASE="5000 02:00:00:00:00:11 192.168.90.51 * *"
# (a) fallback chosen in this process (a FILE where the lease directory should be), cleaned up elsewhere
_saved_leasedir="$HALOW_LEASE_DIR"; HALOW_LEASE_DIR="$HALOW_TEST_TMP/not-a-dir"
halow_dnsmasq_start "${DM_ARGS[@]}" >/dev/null 2>&1
assert_eq "$FB" "${HALOW_DNSMASQ_LEASE_ACTIVE:-}" "the fallback is chosen in this process (variable set here only)"
assert_eq "600" "$(stat -c %a "$FB")" "the fallback file is private (0600)"
assert_eq "$FB" "$(fresh 'halow_dhcp_lease_file')" "a fresh process (variable unset) still resolves the fallback from the durable configuration"
echo "$GOOD_LEASE" > "$FB"
assert_eq "$FB" "$(fresh 'echo "${HALOW_DNSMASQ_LEASE_ACTIVE:-unset-is-empty}" >/dev/null; halow_dnsmasq_lease_file')" "...as the lease file of the station view"
assert_eq "0" "$(grep -c 'laptop' "$FB")" "no host name is written to the fallback"
# (c) while dnsmasq cannot be confirmed stopped nothing is removed: drop the ownership marker
halow_own_clear "net_dnsmasq"
assert_failure "a fresh stop with a live, unowned instance fails (never signalled)" fresh 'halow_dnsmasq_stop'
assert_success "...and the fallback file is still there" test -f "$FB"
assert_success "...and dnsmasq is still running" test -n "$(live_fakes)"
halow_own_mark "net_dnsmasq"
# (a) now a fresh process stops it and the fallback goes
assert_success "a fresh process stops dnsmasq" fresh 'halow_dnsmasq_stop'
assert_eq "" "$(live_fakes)" "...dnsmasq is gone"
assert_file_absent "$FB" "...and the volatile fallback file is gone (the variable never crossed the process boundary)"
assert_eq "$HALOW_LEASE_DIR/dnsmasq.leases" "$(fresh 'halow_dhcp_lease_file')" "...and a fresh process resolves the persistent path again"
# no stale fallback survives a crash: unowned + absent still removes the stale fallback, persistent untouched
HALOW_LEASE_DIR="$_saved_leasedir"
mkdir -p "$HALOW_LEASE_DIR"; echo "$GOOD_LEASE" > "$LEASES"; _before="$(cat "$LEASES")"
echo "$GOOD_LEASE" > "$FB"
assert_success "(b) a stale fallback and a usable persistent database: fresh stop with nothing running" fresh 'halow_dnsmasq_stop'
assert_file_absent "$FB" "...the stale fallback is removed"
assert_eq "$_before" "$(cat "$LEASES")" "...the persistent lease database is untouched"
# (b) a start on usable persistent storage removes a stale fallback and keeps the database
echo "$GOOD_LEASE" > "$FB"
halow_dnsmasq_start "${DM_ARGS[@]}" >/dev/null 2>&1
assert_file_absent "$FB" "a start on usable persistent storage removes a stale volatile file"
assert_eq "$_before" "$(cat "$LEASES")" "...and keeps the persistent database"
echo "$GOOD_LEASE" > "$FB"     # leftover appears while the persistent file is in use
assert_success "a fresh stop (persistent in use)" fresh 'halow_dnsmasq_stop'
assert_file_absent "$FB" "...removes the volatile file"
assert_eq "$_before" "$(cat "$LEASES")" "...and never the persistent database (still the same content)"
# (d) a symbolic link or an unexpected type at the fallback path
echo "$GOOD_LEASE" > "$HALOW_TEST_TMP/link-target"; ln -s "$HALOW_TEST_TMP/link-target" "$FB"
halow_dnsmasq_start "${DM_ARGS[@]}" >/dev/null 2>&1
assert_failure "(d) a symbolic link at the fallback path is removed at start" test -L "$FB"
ln -sf "$HALOW_TEST_TMP/link-target" "$FB"
assert_success "a fresh stop with a symbolic link at the fallback path" fresh 'halow_dnsmasq_stop'
assert_failure "...the link itself is gone" test -L "$FB"
assert_eq "$GOOD_LEASE" "$(cat "$HALOW_TEST_TMP/link-target")" "...and its target is untouched (the link was never followed)"
mkdir -p "$FB/sub"; : > "$FB/sub/x"
assert_success "a fresh stop with a directory at the fallback path" fresh 'halow_dnsmasq_stop'
assert_failure "...the unexpected directory is removed (nothing else is)" test -e "$FB"
assert_eq "$_before" "$(cat "$LEASES")" "...the persistent database is still untouched"
# a fallback start with a symlink/dir at the path yields a private regular file
HALOW_LEASE_DIR="$HALOW_TEST_TMP/not-a-dir"
ln -s "$HALOW_TEST_TMP/link-target" "$FB"
halow_dnsmasq_start "${DM_ARGS[@]}" >/dev/null 2>&1
assert_success "a fallback start replaces a symbolic link with a regular file" test -f "$FB" -a ! -L "$FB"
assert_eq "$GOOD_LEASE" "$(cat "$HALOW_TEST_TMP/link-target")" "...without writing through the link"
assert_success "cleanup in a fresh process" fresh 'halow_dnsmasq_stop'
assert_file_absent "$FB" "...leaves nothing behind"
rm -rf "$HALOW_RUN_DIR"
_halow_dnsmasq_use_fallback
assert_eq "600" "$(stat -c %a "$FB" 2>/dev/null)" "selecting the fallback with no run directory creates it and a private (0600) file"
rm -f "$FB"; mkdir -p "$HALOW_RUN_DIR"
HALOW_LEASE_DIR="$_saved_leasedir"; HALOW_DNSMASQ_LEASE_ACTIVE=""

echo "== test_dnsmasq: an unowned instance is never adopted =="
dnsmasq --conf-file="$CONF" --pid-file="$PIDF" --no-daemon >/dev/null 2>&1 &
_foreign=$!
command sleep 0.3
assert_failure "start refuses while an identity-matching instance runs without a marker" \
    halow_dnsmasq_start halow-br0 192.168.90.1 192.168.90.50 192.168.90.150 12h
assert_failure "...and does not take ownership" halow_own_check net_dnsmasq
assert_exit 1 "stop reports the unowned instance as a hard failure" halow_dnsmasq_stop
assert_success "...and leaves it running (never signalled)" kill -0 "$_foreign"
kill "$_foreign" 2>/dev/null; wait "$_foreign" 2>/dev/null
command sleep 0.2

echo "== test_dnsmasq: a failed start =="
export HALOW_FAKE_DNSMASQ_EXIT=1
assert_failure "a dnsmasq that exits at once is a failed start" halow_dnsmasq_start halow-br0 192.168.90.1 192.168.90.50 192.168.90.150 12h
assert_success "...ownership stays recorded so the stop path cleans up" halow_own_check net_dnsmasq
unset HALOW_FAKE_DNSMASQ_EXIT
assert_success "stop after a failed start" halow_dnsmasq_stop
assert_failure "...clears the marker" halow_own_check net_dnsmasq
assert_file_absent "$CONF" "...and removes the configuration"
assert_failure "an invalid lease time is refused" halow_dnsmasq_start halow-br0 192.168.90.1 192.168.90.50 192.168.90.150 'x;y'
assert_failure "...before anything is owned" halow_own_check net_dnsmasq
assert_failure "missing arguments are refused" halow_dnsmasq_start halow-br0 192.168.90.1

echo "== test_dnsmasq: supervision restarts are bounded =="
halow_dnsmasq_start halow-br0 192.168.90.1 192.168.90.50 192.168.90.150 12h 2>/dev/null
: > "$SLEEPS"
assert_success "running: ensure_running does nothing" halow_dnsmasq_ensure_running
assert_eq "" "$(cat "$SLEEPS")" "...no backoff, no restart"
kill "$(cat "$PIDF")"; command sleep 0.3
_starts="$(grep -c '^dnsmasq ' "$HALOW_FAKE_LOG")"
assert_success "a dead dnsmasq is restarted" halow_dnsmasq_ensure_running
assert_eq "$((_starts + 1))" "$(grep -c '^dnsmasq ' "$HALOW_FAKE_LOG")" "...once"
assert_success "...and is running again" halow_dnsmasq_running
assert_eq "1" "$(head -n1 "$SLEEPS")" "...after a 1 s backoff"
_now=1100
halow_dnsmasq_ensure_running
assert_file_absent "$HALOW_RUN_DIR/dnsmasq.restarts" "a restart that stays up for the stable period resets the count"
kill "$(cat "$PIDF")"; command sleep 0.3
export HALOW_FAKE_DNSMASQ_EXIT=1
: > "$SLEEPS"
assert_exit 0 "restart 1 fails: still trying" halow_dnsmasq_ensure_running
assert_exit 0 "restart 2 fails: still trying" halow_dnsmasq_ensure_running
assert_exit 1 "restart 3 fails: gives up (return 1)" halow_dnsmasq_ensure_running
# Each restart sleeps its backoff, then the start's own 1 s settle check.
assert_eq "1 2 4" "$(awk 'NR%2==1' "$SLEEPS" | tr '\n' ' ' | sed 's/ $//')" "the backoff doubles: 1, 2, 4 s"
_n="$(grep -c '^dnsmasq ' "$HALOW_FAKE_LOG")"
assert_exit 1 "after the limit it stays given up" halow_dnsmasq_ensure_running
assert_eq "$_n" "$(grep -c '^dnsmasq ' "$HALOW_FAKE_LOG")" "...and does not try again"
unset HALOW_FAKE_DNSMASQ_EXIT
halow_dnsmasq_stop 2>/dev/null
HALOW_DNSMASQ_ARGS=()
assert_exit 1 "a process that never started dnsmasq cannot restart it" halow_dnsmasq_ensure_running

echo "== test_dnsmasq: port conflicts =="
SSF="$HALOW_TEST_TMP/ss.out"; export HALOW_FAKE_SS="$SSF"
: > "$SSF"
assert_exit 0 "no listeners: no conflict" halow_dnsmasq_port_conflict_check 192.168.90.1
cat > "$SSF" <<'EOF'
udp   UNCONN 0      0      0.0.0.0:53     0.0.0.0:*
EOF
_out="$(halow_dnsmasq_port_conflict_check 192.168.90.1)"; _rc=$?
assert_eq "1" "$_rc" "a wildcard UDP 53 listener is a conflict"
assert_success "...and the text names the port" grep -q "port 53/udp" <<< "$_out"
cat > "$SSF" <<'EOF'
tcp   LISTEN 0      4096   192.168.90.1:53     0.0.0.0:*
EOF
_out="$(halow_dnsmasq_port_conflict_check 192.168.90.1)"; _rc=$?
assert_eq "1|port 53/tcp is already in use on 192.168.90.1 by another listener" "$_rc|$_out" "a TCP 53 listener on the gateway address is a conflict, named exactly"
cat > "$SSF" <<'EOF'
udp   UNCONN 0      0      0.0.0.0%eth0:67     0.0.0.0:*
EOF
_out="$(halow_dnsmasq_port_conflict_check 192.168.90.1)"; _rc=$?
assert_eq "1" "$_rc" "another DHCP server (UDP 67, bound to a device) is a conflict"
assert_success "...naming port 67" grep -q "port 67/udp" <<< "$_out"
cat > "$SSF" <<'EOF'
udp   UNCONN 0      0      [::]:53     [::]:*
EOF
assert_exit 1 "an IPv6 wildcard listener on 53 is a conflict" halow_dnsmasq_port_conflict_check 192.168.90.1
cat > "$SSF" <<'EOF'
udp   UNCONN 0      0      127.0.0.53%lo:53     0.0.0.0:*
tcp   LISTEN 0      4096   10.0.0.5:53     0.0.0.0:*
tcp   LISTEN 0      4096   0.0.0.0:67     0.0.0.0:*
tcp   LISTEN 0      4096   0.0.0.0:8123     0.0.0.0:*
EOF
assert_exit 0 "listeners on other addresses, TCP 67 and other ports are not conflicts" halow_dnsmasq_port_conflict_check 192.168.90.1
export HALOW_FAKE_SS_RC=1
assert_exit 2 "an unreadable socket list is reported as undeterminable (2), not as no conflict" halow_dnsmasq_port_conflict_check 192.168.90.1
unset HALOW_FAKE_SS_RC HALOW_FAKE_SS

echo "== test_dnsmasq: strict shell options =="
CHILD="$HALOW_TEST_TMP/strict_dnsmasq.sh"
cat > "$CHILD" <<EOF
#!/usr/bin/env bash
set -o errexit -o errtrace -o nounset -o pipefail
shopt -s inherit_errexit
export HALOW_STATE_DIR="$HALOW_STATE_DIR" HALOW_RUN_DIR="$HALOW_RUN_DIR" HALOW_LEASE_DIR="$HALOW_LEASE_DIR" PATH="$PATH" HALOW_FAKE_LOG="$HALOW_FAKE_LOG"
for lib in constants common ownership validate iface_detect network_backend dnsmasq; do . "$HALOW_LIB_DIR/\$lib.sh"; done
halow_dnsmasq_sleep() { command sleep 0.3; }
halow_dnsmasq_start halow-br0 192.168.90.1 192.168.90.50 192.168.90.150 12h
halow_dnsmasq_running
if halow_dnsmasq_port_conflict_check ""; then echo pc=0; else echo pc=\$?; fi
halow_dnsmasq_stop
if halow_dnsmasq_running; then echo still=0; else echo still=\$?; fi
echo CHILD_REACHED_THE_END
EOF
_out="$(bash "$CHILD" 2>&1)"; _rc=$?
assert_eq "0" "$_rc" "start, check, stop run under errexit/nounset/pipefail/inherit_errexit"
assert_success "...an undeterminable port check returns 2 without aborting" grep -q "pc=2" <<< "$_out"
assert_success "...and the stopped instance is no longer running" grep -q "still=1" <<< "$_out"
assert_success "...and the script reached its end" grep -q CHILD_REACHED_THE_END <<< "$_out"

cleanup_fakes
halow_test_teardown
echo "test_dnsmasq: $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed"
exit $([ "$HALOW_TEST_FAILURES" -eq 0 ] && echo 0 || echo 1)
