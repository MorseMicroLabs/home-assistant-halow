#!/usr/bin/env bash
# The unprivileged status service: syntax of the service files, the launcher's logic with
# fakes (port handling, privilege drop, token removal), the Python server over real HTTP
# (tests/status_server_checks.py) and an end-to-end run on a snapshot written by state.sh.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh
. ./helpers_status.sh

echo "== test_status_service =="
halow_status_test_setup
trap halow_status_test_teardown EXIT

STATUS_DIR="$HALOW_STATUS_LIB_DIR/status"
SERVER_PY="$STATUS_DIR/status_server.py"
LAUNCHER="$STATUS_DIR/launcher.sh"

echo "-- service files --"
for f in "$HALOW_STATUS_SVC_DIR/run" "$HALOW_STATUS_SVC_DIR/finish" "$LAUNCHER"; do
    assert_success "bash -n $(basename "$f")" bash -n "$f"
done
assert_eq "#!/usr/bin/with-contenv bashio" "$(sed -n '1p' "$HALOW_STATUS_SVC_DIR/run")" "run uses with-contenv bashio"
assert_eq "#!/usr/bin/with-contenv bashio" "$(sed -n '1p' "$HALOW_STATUS_SVC_DIR/finish")" "finish uses with-contenv bashio"
for f in "$SERVER_PY" "$STATUS_DIR/page.html" "$STATUS_DIR/page.css" "$STATUS_DIR/page.js"; do
    assert_file_exists "$f" "$(basename "$f") present"
done
assert_success "status_server.py parses" python3 -I -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$SERVER_PY"
assert_success "the server imports only the standard library" python3 -I - "$SERVER_PY" <<'PY'
import ast, sys
tree = ast.parse(open(sys.argv[1]).read())
names = set()
for node in ast.walk(tree):
    if isinstance(node, ast.Import):
        names.update(a.name.split(".")[0] for a in node.names)
    elif isinstance(node, ast.ImportFrom):
        names.add((node.module or "").split(".")[0])
stdlib = getattr(sys, "stdlib_module_names", None)
bad = [n for n in names if stdlib is not None and n not in stdlib]
sys.exit(1 if bad else 0)
PY
assert_success "no file in the service directory is CRLF" bash -c '! grep -l $'"'"'\r'"'"' "$@"' _ "$STATUS_DIR"/* "$HALOW_STATUS_SVC_DIR"/*

echo "-- launcher with fakes --"
FAKEBIN="$HALOW_TEST_TMP/fakebin"; mkdir -p "$FAKEBIN"
EXEC_ARGS="$HALOW_TEST_TMP/exec.args"; EXEC_ENV="$HALOW_TEST_TMP/exec.env"; SLEEPS="$HALOW_TEST_TMP/sleeps"
PROBES="$HALOW_TEST_TMP/probes"
# The fake s6-setuidgid runs the launcher's probes ("true", "cat -- <file>") as an
# unprivileged other user would see them: a file is readable only if its "other" read
# bit and its directory's "other" search bit are set (so the result does not depend on
# the uid running the tests). FAKE_SETUIDGID_BROKEN=1 makes every probe fail. Any other
# command is the exec of the server: its arguments and environment are recorded.
cat > "$FAKEBIN/s6-setuidgid" <<EOF
#!/usr/bin/env bash
user="\$1"; shift
case "\${1:-}" in
    true|cat)
        printf '%s %s\n' "\$user" "\$*" >> "$PROBES"
        [ "\${FAKE_SETUIDGID_BROKEN:-0}" = 0 ] || exit 1
        [ "\$1" = true ] && exit 0
        f="\${3:-}"; d="\$(dirname "\$f")"
        fp="\$(stat -c %A "\$f" 2>/dev/null)" || exit 1
        dp="\$(stat -c %A "\$d" 2>/dev/null)" || exit 1
        [ "\${fp:7:1}" = r ] && [ "\${dp:9:1}" = x ] || exit 1
        cat -- "\$f" >/dev/null
        exit \$?
        ;;
esac
printf '%s\n' "\$user" "\$@" > "$EXEC_ARGS"
env > "$EXEC_ENV"
exit 0
EOF
# The status user "halowstatus" has the ids of whoever runs the tests, so the launcher's
# chown (to those ids) really works and the owner it checks afterwards is real.
ME_U="$(command id -u)"; ME_G="$(command id -g)"
cat > "$FAKEBIN/id" <<EOF
#!/usr/bin/env bash
[ "\${1:-}" = "-u" ] && [ "\${2:-}" = "halowstatus" ] && { echo $ME_U; exit 0; }
[ "\${1:-}" = "-g" ] && [ "\${2:-}" = "halowstatus" ] && { [ "\${FAKE_ID_G_FAILS:-0}" = 1 ] && exit 1; echo $ME_G; exit 0; }
exit 1
EOF
# The fake chown records its arguments, then does the real thing (or fails when told to).
CHOWNS="$HALOW_TEST_TMP/chowns"
cat > "$FAKEBIN/chown" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CHOWNS"
[ "\${FAKE_CHOWN_FAILS:-0}" = 0 ] || exit 1
exec /bin/chown "\$@"
EOF
# The fake mkdir records its arguments and creates nothing when FAKE_MKDIR_NOOP is set.
MKDIRS="$HALOW_TEST_TMP/mkdirs"
cat > "$FAKEBIN/mkdir" <<EOF
#!/usr/bin/env bash
if [ "\${FAKE_MKDIR_NOOP:-0}" = 1 ]; then printf '%s\n' "\$*" >> "$MKDIRS"; exit 0; fi
exec /bin/mkdir "\$@"
EOF
# Likewise rm: with FAKE_MKDIR_NOOP set nothing is removed (a test of the production path
# must never touch a real /run/halow-status).
cat > "$FAKEBIN/rm" <<EOF
#!/usr/bin/env bash
if [ "\${FAKE_MKDIR_NOOP:-0}" = 1 ]; then exit 0; fi
exec /bin/rm "\$@"
EOF
cat > "$FAKEBIN/sleep" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SLEEPS"
exit 0
EOF
chmod +x "$FAKEBIN"/*

# A container environment directory like the hardened one: directory 0700, token files
# 0600, a non-secret file 0644.
CENV="$HALOW_TEST_TMP/container_environment"
mkdir -p "$CENV"
printf 'canary-supervisor-token-value' > "$CENV/SUPERVISOR_TOKEN"
printf 'canary-hassio-token-value' > "$CENV/HASSIO_TOKEN"
printf 'Etc/UTC' > "$CENV/TZ"
harden_cenv() { chmod 0700 "$CENV"; chmod 0600 "$CENV/SUPERVISOR_TOKEN" "$CENV/HASSIO_TOKEN"; chmod 0644 "$CENV/TZ"; }
harden_cenv
PORT_FILE="$HALOW_RUN_DIR/status.port"
READY_FILE="$HALOW_RUN_DIR/.ready"
HB_DIR="$HALOW_TEST_TMP/halow-status"
HB_FILE="$HB_DIR/heartbeat"

# run_launcher <log file> [VAR=value ...] — runs halow_status_launcher_main in a subshell
# with fakes first on PATH, a fake bashio (port from FAKE_BASHIO_PORT, "none" = no bashio
# port function at all) and Supervisor tokens in the environment. Prints the exit code.
run_launcher() {
    local log="$1"; shift
    rm -f "$EXEC_ARGS" "$EXEC_ENV" "$SLEEPS" "$PROBES" "$PORT_FILE" "$CHOWNS"
    (
        export HALOW_STATUS_HEARTBEAT_FILE="$HB_FILE" HALOW_STATUS_TEST_MODE=1
        export PATH="$FAKEBIN:$PATH"
        export SUPERVISOR_TOKEN=supervisor-token-value HASSIO_TOKEN=hassio-token-value
        export HALOW_LIB_DIR="$HALOW_STATUS_LIB_DIR"
        export HALOW_S6_CONTAINER_ENV_DIR="$CENV"
        unset HALOW_STATUS_PORT HALOW_STATUS_STALE_AFTER_S HALOW_RUN_READY_FILE HALOW_STATUS_PORT_FILE
        local kv
        for kv in "$@"; do export "${kv?}"; done
        bashio::log.info() { printf 'INFO %s\n' "$*" >> "$log"; }
        bashio::log.warning() { printf 'WARN %s\n' "$*" >> "$log"; }
        bashio::log.error() { printf 'ERROR %s\n' "$*" >> "$log"; }
        case "${FAKE_BASHIO_PORT:-none}" in
            none) ;;
            addon:*) bashio::addon.ingress_port() { printf '%s\n' "${FAKE_BASHIO_PORT#addon:}"; } ;;
            *) bashio::app.ingress_port() { printf '%s\n' "$FAKE_BASHIO_PORT"; } ;;
        esac
        . "$HALOW_STATUS_LIB_DIR/constants.sh"
        . "$LAUNCHER"
        halow_status_launcher_main
    )
    echo "$?"
}

mkdir -p "$HALOW_RUN_DIR"
: > "$READY_FILE"
LOG="$HALOW_TEST_TMP/launcher.log"
rc="$(run_launcher "$LOG" FAKE_BASHIO_PORT=8099)"
assert_eq "0" "$rc" "launcher execs the server when the Ingress port is known"
assert_file_exists "$EXEC_ARGS" "the server was started through s6-setuidgid"
mapfile -t ARGS < "$EXEC_ARGS" 2>/dev/null || ARGS=()
assert_eq "halowstatus" "${ARGS[0]:-}" "dropped to the unprivileged status user"
assert_eq "python3" "${ARGS[1]:-}" "the server runs under python3"
assert_eq "$SERVER_PY" "${ARGS[2]:-}" "the server program"
assert_eq "--port 8099 --bind 172.30.32.1 --allow-from 172.30.32.2 --snapshot $HALOW_STATUS_FILE --stale-after 90 --heartbeat-file $HB_FILE" \
    "${ARGS[*]:3}" "port, bind, allowed peer (exactly 172.30.32.2), snapshot, stale threshold (90 s) and the liveness counter path passed; nothing else"
assert_eq "700" "$(file_mode "$HB_DIR" 2>/dev/null)" "the dedicated liveness directory is mode 0700"
assert_eq "$ME_U:$ME_G -- $HB_DIR" "$(cat "$CHOWNS" 2>/dev/null)" "...owned by the status user and its group (the only chown the launcher makes)"
assert_file_absent "$HB_FILE" "no counter file exists before the server starts (the server writes the first one)"
assert_eq "0" "$(count_in_file "$EXEC_ENV" "SUPERVISOR_TOKEN")" "the child never receives SUPERVISOR_TOKEN"
assert_eq "0" "$(count_in_file "$EXEC_ENV" "HASSIO_TOKEN")" "the child never receives HASSIO_TOKEN"
assert_eq "0" "$(count_in_file "$EXEC_ENV" "token-value")" "no token value in the child's environment"
assert_eq "0" "$(count_in_file "$EXEC_ARGS" "token")" "no token on the command line"
assert_eq "8099" "$(cat "$PORT_FILE" 2>/dev/null)" "the listening port is recorded in the port file"
assert_eq "644" "$(file_mode "$PORT_FILE" 2>/dev/null)" "the port file is mode 0644"
assert_eq "1" "$(count_in_file "$PROBES" "halowstatus cat -- $CENV/SUPERVISOR_TOKEN")" "the token file was probed as the status user"
assert_eq "1" "$(count_in_file "$PROBES" "halowstatus cat -- $CENV/HASSIO_TOKEN")" "the second token file was probed as the status user"
assert_eq "0" "$(count_in_file "$PROBES" "TZ")" "only token files are probed"
assert_eq "0" "$(count_in_file "$LOG" "canary")" "no token value in the launcher log"

rc="$(run_launcher "$LOG" FAKE_BASHIO_PORT=8099 HALOW_STATUS_PORT=12345)"
mapfile -t ARGS < "$EXEC_ARGS" 2>/dev/null || ARGS=()
assert_eq "0 12345" "$rc ${ARGS[4]:-}" "HALOW_STATUS_PORT overrides bashio (tests)"

rc="$(run_launcher "$LOG" FAKE_BASHIO_PORT=addon:8123)"
mapfile -t ARGS < "$EXEC_ARGS" 2>/dev/null || ARGS=()
assert_eq "0 8123" "$rc ${ARGS[4]:-}" "older bashio (addon namespace) also supported"

rc="$(run_launcher "$LOG" FAKE_BASHIO_PORT=8099 HALOW_STATUS_BIND=127.0.0.9 HALOW_STATUS_ALLOW_FROM=127.0.0.8 HALOW_STATUS_USER=halowstatus)"
mapfile -t ARGS < "$EXEC_ARGS" 2>/dev/null || ARGS=()
assert_eq "127.0.0.9 127.0.0.8" "${ARGS[6]:-} ${ARGS[8]:-}" "bind and allowed peer come from the environment"

for bad in null "" 0 70000 abc "80 81" -1; do
    : > "$LOG"
    rc="$(run_launcher "$LOG" "FAKE_BASHIO_PORT=$bad")"
    HALOW_TEST_COUNT=$((HALOW_TEST_COUNT + 1))
    if [ "$rc" != "0" ] && [ ! -e "$EXEC_ARGS" ] && grep -q '^ERROR .*Ingress port' "$LOG" && grep -qx '5' "$SLEEPS" 2>/dev/null; then
        echo "  ok: port '$bad' refused: error logged, short sleep, non-zero exit, no server started"
    else
        echo "  FAIL: port '$bad' not refused correctly (rc=$rc)"
        HALOW_TEST_FAILURES=$((HALOW_TEST_FAILURES + 1))
    fi
done
: > "$LOG"
rc="$(run_launcher "$LOG" FAKE_BASHIO_PORT=none)"
assert_success "no bashio and no override: refused, never a guessed port" \
    bash -c '[ "$1" != 0 ] && [ ! -e "$2" ]' _ "$rc" "$EXEC_ARGS"

: > "$LOG"
rc="$(run_launcher "$LOG" FAKE_BASHIO_PORT=8099 HALOW_STATUS_USER=nosuchuser)"
assert_success "a missing status user is refused (never runs the server as root)" \
    bash -c '[ "$1" != 0 ] && [ ! -e "$2" ] && grep -q "^ERROR .*nosuchuser" "$3"' _ "$rc" "$EXEC_ARGS" "$LOG"

: > "$LOG"
rc="$(run_launcher "$LOG" FAKE_BASHIO_PORT=8099 HALOW_STATUS_SERVER="$HALOW_TEST_TMP/missing.py")"
assert_success "a missing server program is refused" bash -c '[ "$1" != 0 ] && [ ! -e "$2" ]' _ "$rc" "$EXEC_ARGS"

echo "-- launcher: the Supervisor token must not be readable by the status user --"
for case_ in "file:SUPERVISOR_TOKEN" "file:HASSIO_TOKEN"; do
    harden_cenv
    chmod 0644 "$CENV/${case_#file:}"; chmod 0755 "$CENV"; name="${case_#file:}"
    : > "$LOG"
    rc="$(run_launcher "$LOG" FAKE_BASHIO_PORT=8099)"
    assert_success "a readable token ($case_): refused with a non-zero exit, no server started" \
        bash -c '[ "$1" != 0 ] && [ ! -e "$2" ]' _ "$rc" "$EXEC_ARGS"
    assert_success "a readable token ($case_): a clear error naming the file is logged" \
        grep -q "^ERROR .*$name is readable by the unprivileged user 'halowstatus'.*refusing" "$LOG"
    assert_file_absent "$PORT_FILE" "a readable token ($case_): no port file written"
    assert_eq "0" "$(count_in_file "$LOG" "canary")" "a readable token ($case_): the token value is never logged"
    assert_success "a readable token ($case_): short pause before s6 tries again" grep -qx '5' "$SLEEPS"
done
harden_cenv
chmod 0755 "$CENV"
: > "$LOG"
rc="$(run_launcher "$LOG" FAKE_BASHIO_PORT=8099)"
assert_eq "0" "$rc" "a listable directory with private token files is accepted"
harden_cenv
chmod 0644 "$CENV/SUPERVISOR_TOKEN" "$CENV/HASSIO_TOKEN"
: > "$LOG"
rc="$(run_launcher "$LOG" FAKE_BASHIO_PORT=8099)"
assert_eq "0" "$rc" "token files in a directory the user cannot enter are accepted"
harden_cenv
: > "$LOG"
rc="$(run_launcher "$LOG" FAKE_BASHIO_PORT=8099 FAKE_SETUIDGID_BROKEN=1)"
assert_success "a check that cannot be made (probe as the user fails) is refused (fail closed)" \
    bash -c '[ "$1" != 0 ] && [ ! -e "$2" ] && grep -q "^ERROR .*could not verify" "$3"' _ "$rc" "$EXEC_ARGS" "$LOG"
: > "$LOG"
rc="$(run_launcher "$LOG" FAKE_BASHIO_PORT=8099 HALOW_S6_CONTAINER_ENV_DIR="$HALOW_TEST_TMP/no-such-dir")"
assert_eq "0" "$rc" "without a container environment directory there is nothing to protect"

echo "-- launcher: the manager's ready file --"
rm -f "$READY_FILE"
: > "$LOG"
rc="$(run_launcher "$LOG" FAKE_BASHIO_PORT=8099 HALOW_STATUS_RUN_WAIT_S=3)"
assert_success "no ready file: refused with a non-zero exit, no server started" \
    bash -c '[ "$1" != 0 ] && [ ! -e "$2" ]' _ "$rc" "$EXEC_ARGS"
assert_eq "1 1 1 5" "$(tr '\n' ' ' < "$SLEEPS" | sed 's/ $//')" "the wait for the ready file is bounded, then a short pause"
assert_success "the wait is logged as an error" grep -q '^ERROR .*not ready' "$LOG"
assert_file_absent "$PORT_FILE" "nothing is written under the run directory before the ready file exists"
assert_eq "" "$(cat "$PROBES" 2>/dev/null)" "nothing else is done before the ready file exists"
: > "$LOG"
rc="$(run_launcher "$LOG" FAKE_BASHIO_PORT=8099 HALOW_RUN_READY_FILE="$HALOW_TEST_TMP/elsewhere.ready" HALOW_STATUS_RUN_WAIT_S=1)"
assert_success "the ready file path comes from HALOW_RUN_READY_FILE" bash -c '[ "$1" != 0 ] && [ ! -e "$2" ]' _ "$rc" "$EXEC_ARGS"
: > "$HALOW_TEST_TMP/elsewhere.ready"
rc="$(run_launcher "$LOG" FAKE_BASHIO_PORT=8099 HALOW_RUN_READY_FILE="$HALOW_TEST_TMP/elsewhere.ready" HALOW_STATUS_PORT_FILE="$HALOW_TEST_TMP/p.port")"
assert_eq "0 8099" "$rc $(cat "$HALOW_TEST_TMP/p.port" 2>/dev/null)" "the port file path comes from HALOW_STATUS_PORT_FILE"
: > "$READY_FILE"
: > "$LOG"
rc="$(run_launcher "$LOG" FAKE_BASHIO_PORT=8099 HALOW_STATUS_PORT_FILE="$HALOW_TEST_TMP/no-such-dir/p.port")"
assert_success "a port file that cannot be written is refused" \
    bash -c '[ "$1" != 0 ] && [ ! -e "$2" ] && grep -q "^ERROR .*liveness" "$3"' _ "$rc" "$EXEC_ARGS" "$LOG"

echo "-- launcher: the dedicated liveness directory --"
: > "$READY_FILE"
rm -rf "$HB_DIR"
: > "$LOG"
rc="$(run_launcher "$LOG" FAKE_BASHIO_PORT=8099)"
assert_eq "0" "$rc" "the directory is created when it does not exist"
assert_eq "700" "$(file_mode "$HB_DIR")" "mode 0700"
# stale files of an earlier run are removed before the server starts
rm -rf "$HB_DIR"; mkdir -p "$HB_DIR"; chmod 0755 "$HB_DIR"
printf '999\n' > "$HB_FILE"; printf '999\n' > "$HB_FILE.tmp"; printf 'x' > "$HB_DIR/unrelated"
: > "$LOG"
rc="$(run_launcher "$LOG" FAKE_BASHIO_PORT=8099)"
assert_eq "0" "$rc" "an existing directory is reused"
assert_eq "700" "$(file_mode "$HB_DIR")" "...and set to mode 0700"
assert_file_absent "$HB_FILE" "a counter file left by an earlier run is removed before the server starts"
assert_file_absent "$HB_FILE.tmp" "a temporary file left by an earlier run is removed too"
assert_file_absent "$HB_DIR/unrelated" "the whole directory is emptied: nothing of an earlier life survives"
assert_eq "" "$(ls -A "$HB_DIR")" "the prepared directory is empty"
assert_eq "$ME_U" "$(stat -c %u "$HB_DIR")" "the prepared directory is owned by the status user (checked on the file system)"
# whatever an earlier life left at the two names must not keep the service from starting
VICTIM="$HALOW_TEST_TMP/victim"; printf 'untouched\n' > "$VICTIM"
for kind in directory fifo symlink "directory with content" "symlink to a directory"; do
    rm -rf "$HB_DIR"; mkdir -p "$HB_DIR"; : > "$LOG"
    for name in "$HB_FILE" "$HB_FILE.tmp"; do
        case "$kind" in
            directory) mkdir "$name" ;;
            fifo) mkfifo "$name" ;;
            symlink) ln -s "$VICTIM" "$name" ;;
            "directory with content") mkdir -p "$name/sub"; : > "$name/sub/f" ;;
            "symlink to a directory") mkdir -p "$HALOW_TEST_TMP/elsewhere"; : > "$HALOW_TEST_TMP/elsewhere/keep"; ln -s "$HALOW_TEST_TMP/elsewhere" "$name" ;;
        esac
    done
    rc="$(run_launcher "$LOG" FAKE_BASHIO_PORT=8099)"
    assert_success "[$kind at both names] the launcher still starts the server and leaves an empty 0700 directory" \
        bash -c '[ "$1" = 0 ] && [ -e "$2" ] && [ -z "$(ls -A "$3")" ] && [ "$(stat -c %a "$3")" = 700 ]' _ "$rc" "$EXEC_ARGS" "$HB_DIR"
    assert_eq "untouched" "$(cat "$VICTIM")" "[$kind] a link's target is never followed"
    chmod -R u+rwx "$HB_DIR" 2>/dev/null || :
done
assert_file_exists "$HALOW_TEST_TMP/elsewhere/keep" "the content behind a symbolic link to a directory is untouched"
rm -rf "$HB_DIR" "$HALOW_TEST_TMP/elsewhere"
# production ignores a path override: only /run/halow-status/heartbeat, whatever the environment says
: > "$MKDIRS"; : > "$LOG"
if [ -e /run/halow-status ]; then
    echo "  note: /run/halow-status exists on this machine; the production-path checks were SKIPPED (they must never touch it)"
else
rc="$(run_launcher "$LOG" FAKE_BASHIO_PORT=8099 HALOW_STATUS_TEST_MODE=0 FAKE_MKDIR_NOOP=1)"
assert_success "without the test flag the override is ignored: the launcher works on /run/halow-status only (and, finding no such directory here, refuses)" \
    bash -c '[ "$1" != 0 ] && [ ! -e "$2" ] && [ "$(cat "$3")" = "-p -- /run/halow-status" ]' _ "$rc" "$HB_DIR" "$MKDIRS"
: > "$LOG"
rc="$(run_launcher "$LOG" FAKE_BASHIO_PORT=8099 HALOW_STATUS_TEST_MODE=yes FAKE_MKDIR_NOOP=1)"
assert_success "only the exact value 1 enables the override" bash -c '[ "$1" != 0 ] && [ ! -e "$2" ]' _ "$rc" "$HB_DIR"
fi
assert_eq "/run/halow-status/heartbeat" "$(env -u HALOW_STATUS_TEST_MODE HALOW_STATUS_HEARTBEAT_FILE=/elsewhere/x bash -c '. "$1"; halow_status_heartbeat_file' _ "$LAUNCHER")" "halow_status_heartbeat_file: production path with an override in the environment"
assert_eq "$HB_FILE" "$(HALOW_STATUS_TEST_MODE=1 HALOW_STATUS_HEARTBEAT_FILE="$HB_FILE" bash -c '. "$1"; halow_status_heartbeat_file' _ "$LAUNCHER")" "halow_status_heartbeat_file: the override is honoured only with HALOW_STATUS_TEST_MODE=1"
rm -rf "$HB_DIR"
# refusals: the server is not started, nothing recorded
for case_ in "dir not named halow-status" "file not named heartbeat" "symlink" "regular file" "chown fails" "id -g fails" "dir is /run" "dir is root" "dir is the run directory" "dir is /tmp" "file name empty" "file name dot-dot"; do
    rm -rf "$HB_DIR"; : > "$LOG"; extra=""; hb="$HB_FILE"
    case "$case_" in
        "dir not named halow-status") hb="$HALOW_TEST_TMP/other/heartbeat" ;;
        "file not named heartbeat") hb="$HB_DIR/counter" ;;
        symlink) mkdir -p "$HALOW_TEST_TMP/elsewhere"; ln -s "$HALOW_TEST_TMP/elsewhere" "$HB_DIR" ;;
        "regular file") : > "$HB_DIR" ;;
        "chown fails") extra="FAKE_CHOWN_FAILS=1" ;;
        "id -g fails") extra="FAKE_ID_G_FAILS=1" ;;
        "dir is /run") hb="/run/heartbeat" ;;
        "dir is root") hb="/heartbeat" ;;
        "dir is the run directory") hb="$HALOW_RUN_DIR/heartbeat" ;;
        "dir is /tmp") hb="/tmp/heartbeat" ;;
        "file name empty") hb="$HB_DIR/" ;;
        "file name dot-dot") hb="$HB_DIR/.." ;;
    esac
    rc="$(run_launcher "$LOG" FAKE_BASHIO_PORT=8099 "HALOW_STATUS_HEARTBEAT_FILE=$hb" ${extra:+"$extra"})"
    assert_success "[$case_] refused: non-zero exit, no server, no port recorded, error logged, short pause" \
        bash -c '[ "$1" != 0 ] && [ ! -e "$2" ] && [ ! -e "$3" ] && grep -q "^ERROR .*liveness directory could not be prepared" "$4" && grep -qx 5 "$5"' _ "$rc" "$EXEC_ARGS" "$PORT_FILE" "$LOG" "$SLEEPS"
done
rm -rf "$HB_DIR" "$HALOW_TEST_TMP/elsewhere"
: > "$LOG"
rm -f "$READY_FILE"
rc="$(run_launcher "$LOG" FAKE_BASHIO_PORT=8099 HALOW_STATUS_RUN_WAIT_S=1)"
assert_file_absent "$HB_DIR" "no ready file: the liveness directory is not created either"
: > "$READY_FILE"
chmod 0755 "$CENV"; chmod 0644 "$CENV/SUPERVISOR_TOKEN"
rc="$(run_launcher "$LOG" FAKE_BASHIO_PORT=8099)"
assert_file_absent "$HB_DIR" "a readable token file: the liveness directory is not created either"
harden_cenv

echo "-- the peer allow list: exactly the Ingress proxy, in every default --"
assert_eq "1" "$(grep -c -x ': "${HALOW_STATUS_ALLOW_FROM:=172.30.32.2}"' "$HALOW_STATUS_LIB_DIR/constants.sh")" "constants.sh: the default allowed peer is exactly 172.30.32.2"
assert_eq "172.30.32.2" "$(env -i bash -c '. "$1"; printf "%s" "$HALOW_STATUS_ALLOW_FROM"' _ "$HALOW_STATUS_LIB_DIR/constants.sh")" "constants.sh sourced with no environment yields 172.30.32.2"
assert_eq "1" "$(grep -c -F -- '--allow-from "${HALOW_STATUS_ALLOW_FROM:-172.30.32.2}"' "$LAUNCHER")" "launcher.sh: the default allowed peer is exactly 172.30.32.2"
assert_eq "1" "$(grep -c -F 'env_default("HALOW_STATUS_ALLOW_FROM", "172.30.32.2")' "$SERVER_PY")" "status_server.py: the default allowed peer is exactly 172.30.32.2"
assert_failure "no file of the product sets or documents a status peer of 172.30.32.1, loopback or the host network" \
    grep -rEn 'ALLOW_FROM[^#]*(172\.30\.32\.1([^0-9]|$)|127\.|0\.0\.0\.0|any)|--allow-from[[:space:]]+(172\.30\.32\.1([^0-9]|$)|127\.|any)' \
        "$HALOW_STATUS_LIB_DIR" "$HALOW_STATUS_ADDON_DIR/Dockerfile" "$HALOW_STATUS_ADDON_DIR/config.yaml" "$HALOW_STATUS_SVC_DIR"
assert_failure "the launcher never lists a second peer" grep -qE 'ALLOW_FROM:-[^}]*[, ]' "$LAUNCHER"

echo "-- the real run and finish scripts --"
rm -f "$EXEC_ARGS" "$EXEC_ENV"
env PATH="$FAKEBIN:$PATH" HALOW_LIB_DIR="$HALOW_STATUS_LIB_DIR" HALOW_STATUS_PORT=8124 HALOW_STATUS_HEARTBEAT_FILE="$HB_FILE" HALOW_STATUS_TEST_MODE=1 \
    SUPERVISOR_TOKEN=supervisor-token-value HALOW_RUN_DIR="$HALOW_RUN_DIR" HALOW_S6_CONTAINER_ENV_DIR="$CENV" \
    bash "$HALOW_STATUS_SVC_DIR/run" >/dev/null 2>&1
assert_eq "0" "$?" "run execs the launcher"
mapfile -t ARGS < "$EXEC_ARGS" 2>/dev/null || ARGS=()
assert_eq "halowstatus 8124" "${ARGS[0]:-} ${ARGS[4]:-}" "run starts the server as the status user on the port"
assert_eq "0" "$(count_in_file "$EXEC_ENV" "token-value")" "run never passes the token on"
rm -f "$EXEC_ARGS"
env PATH="$FAKEBIN:$PATH" HALOW_LIB_DIR="$HALOW_STATUS_LIB_DIR" HALOW_RUN_DIR="$HALOW_RUN_DIR" HALOW_S6_CONTAINER_ENV_DIR="$CENV" \
    bash "$HALOW_STATUS_SVC_DIR/run" >/dev/null 2>&1
rc=$?
assert_success "run without a port exits non-zero and starts nothing" bash -c '[ "$1" != 0 ] && [ ! -e "$2" ]' _ "$rc" "$EXEC_ARGS"
out="$(bash "$HALOW_STATUS_SVC_DIR/finish" 3 2>&1)"
assert_eq "0" "$?" "finish exits 0"
assert_success "finish logs the exit code" bash -c '[[ "$1" == *"exit code 3"* ]]' _ "$out"

echo "-- the server over real HTTP --"
CHECKS_OUT="$HALOW_TEST_TMP/checks.out"
python3 -I ./status_server_checks.py "$SERVER_PY" "$HALOW_STATUS_LIB_DIR/errors.sh" "$HALOW_TEST_TMP/http" > "$CHECKS_OUT" 2>&1
checks_rc=$?
cat "$CHECKS_OUT"
ok_n="$(grep -c '^  ok: ' "$CHECKS_OUT")"
fail_n="$(grep -c '^  FAIL: ' "$CHECKS_OUT")"
HALOW_TEST_COUNT=$((HALOW_TEST_COUNT + ok_n + fail_n))
HALOW_TEST_FAILURES=$((HALOW_TEST_FAILURES + fail_n))
assert_eq "0" "$checks_rc" "the HTTP checks exit 0"
skipped_n="$(grep -oE 'SKIPPED block \([0-9]+' "$CHECKS_OUT" | grep -oE '[0-9]+' | awk '{s += $1} END {print s + 0}')"
SKIPPED_BLOCKS_N="$(grep -c 'SKIPPED block' "$CHECKS_OUT")"
assert_eq "253" "$((ok_n + fail_n + skipped_n))" "the HTTP checks: exactly the planned 253 (run $((ok_n + fail_n)), skipped $skipped_n in $SKIPPED_BLOCKS_N block(s))"
assert_file_absent "$STATUS_DIR/__pycache__" "the checks leave no bytecode cache in the product tree"

echo "-- end to end: a snapshot written by state.sh, served over HTTP --"
PP="pass""phrase"
E2E_SECRET="Wobbly-Lantern-Quartz-77"
export HALOW_STATE_NOW=""
unset HALOW_STATE_NOW
halow_state_init
halow_state_region AU
halow_state_radio_requested automatic 1 ""
halow_state_adapter true wlan1
halow_state_radio_effective 923000 42 1 fallback implemented false
halow_state_advisory RADIO_AUTO_FALLBACK
halow_state_backend true halow-br0 10.42.0.0/24 10.42.0.1
_now_s="$(date +%s)"
printf '%s\n' "S|<script>alert(1)</script>|true|ordinary|1|1|0" "SI|192.0.2.99|dhcp|0" \
    "S|02:00:00:00:00:30|true|wds|$_now_s|$_now_s|0" "SI|192.0.2.80|dhcp|0" "D|02:00:00:00:01:01" "DI|192.0.2.59|dhcp+neighbour|0" \
    "D|02:00:00:00:01:02" "DI|<img src=x onerror=alert(1)>|dhcp|0" > "$HALOW_TEST_TMP/st.txt"
halow_state_stations_set "$HALOW_TEST_TMP/st.txt"
halow_state_diag_set config "wifi_${PP}=${E2E_SECRET}"
halow_state_diag_log_append "{\"${PP}\": \"${E2E_SECRET}\"}"
HALOW_CFG_WIFI_PASSPHRASE="$E2E_SECRET" halow_state_diag_set note "mistake ${E2E_SECRET}"
halow_state_overall operating
assert_eq "0" "$(count_in_file "$HALOW_STATUS_FILE" "$E2E_SECRET")" "the passphrase is not in the snapshot file"
HALOW_E2E_SNAPSHOT="$HALOW_STATUS_FILE" HALOW_E2E_SECRET="$E2E_SECRET" \
    python3 -I ./status_server_checks.py "$SERVER_PY" "$HALOW_STATUS_LIB_DIR/errors.sh" "$HALOW_TEST_TMP/e2e" > "$CHECKS_OUT" 2>&1
checks_rc=$?
cat "$CHECKS_OUT"
ok_n="$(grep -c '^  ok: ' "$CHECKS_OUT")"
fail_n="$(grep -c '^  FAIL: ' "$CHECKS_OUT")"
HALOW_TEST_COUNT=$((HALOW_TEST_COUNT + ok_n + fail_n))
HALOW_TEST_FAILURES=$((HALOW_TEST_FAILURES + fail_n))
assert_eq "0" "$checks_rc" "the end-to-end checks exit 0"
assert_success "the end-to-end checks ran" test "$ok_n" -ge 5
leftover="$(pgrep -f -- "$HALOW_TEST_TMP/" 2>/dev/null || true)"
assert_eq "" "$leftover" "no server process started by these checks is left running (only this run's processes are looked at)"

echo "test_status_service: $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed, ${SKIPPED_BLOCKS_N:-0} skipped blocks"
exit $([ "$HALOW_TEST_FAILURES" -eq 0 ] && echo 0 || echo 1)
