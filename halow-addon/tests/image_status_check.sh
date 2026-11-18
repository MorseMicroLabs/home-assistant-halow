#!/usr/bin/env bash
# in-image check of the status service's privilege drop, run inside the
# real image (entrypoint overridden; no s6, no Supervisor):
#   - the image's own python3 compiles the status server;
#   - the real launcher refuses to start (and writes nothing) before the manager's ready
#     file exists, and refuses when a token file is readable by the status user (checked
#     with the image's real s6-setuidgid); it records the listening port (0644) otherwise;
#   - the real launcher, started as root, runs the server as the unprivileged status user
#     with no effective, permitted or ambient capabilities and no Supervisor token in its
#     environment;
#   - the launcher prepares the status user's liveness directory (mode 0700, owned by the
#     status user) and the server writes its counter there (mode 0600);
#   - the server answers GET /health and refuses POST, bound to the loopback address used
#     here in place of the Supervisor's address;
#   - the server refuses to run as root when started directly.
# Invoked by tests/verify_image.sh as:
#   docker run --rm --network none --entrypoint /bin/bash <image> <this file>
set -eu
set -o pipefail

fails=0
check() { # check <description> <command...>
    local d="$1"; shift
    if "$@"; then echo "  ok: $d"; else echo "  FAIL: $d"; fails=$((fails + 1)); fi
}

echo "-- the image's python compiles the status server --"
check "python3 -m py_compile status_server.py (image python $(python3 -c 'import platform; print(platform.python_version())'))" \
    env PYTHONPYCACHEPREFIX=/tmp/_halow_pycache python3 -m py_compile /usr/lib/halow/status/status_server.py

echo "-- the status launcher (real s6-setuidgid, real python3) --"
export HALOW_RUN_DIR=/tmp/_halow_run HALOW_STATUS_PORT=18099 HALOW_STATUS_BIND=127.0.0.1 HALOW_STATUS_ALLOW_FROM=127.0.0.1
export HALOW_STATUS_HEARTBEAT_FILE=/tmp/_halow_hb/halow-status/heartbeat HALOW_STATUS_TEST_MODE=1
export SUPERVISOR_TOKEN=placeholder-not-a-real-value
export HALOW_STATUS_RETRY_SLEEP_S=0
mkdir -p "$HALOW_RUN_DIR"

echo "-- the launcher refuses to start before the manager's ready file exists, and writes nothing --"
mkdir -p /tmp/_halow_notready
LAUNCH='. /usr/lib/halow/constants.sh; . /usr/lib/halow/status/launcher.sh; halow_status_launcher_main'
if HALOW_RUN_DIR=/tmp/_halow_notready HALOW_STATUS_RUN_WAIT_S=1 HALOW_STATUS_PORT=18096 \
        timeout 20 bash -c "$LAUNCH" > /tmp/_halow_notready.log 2>&1; then nr=0; else nr=$?; fi
check "without the ready file the launcher returns non-zero, without hanging (rc $nr)" bash -c '[ "$0" -ne 0 ] && [ "$0" -ne 124 ]' "$nr"
check "and wrote nothing under that run directory" test -z "$(ls -A /tmp/_halow_notready)"

echo "-- the launcher refuses to start when a token file is readable by the status user --"
mkdir -p /tmp/_halow_fakeenv
printf 'placeholder' > /tmp/_halow_fakeenv/SUPERVISOR_TOKEN
chmod 0755 /tmp/_halow_fakeenv; chmod 0644 /tmp/_halow_fakeenv/SUPERVISOR_TOKEN
touch "$HALOW_RUN_DIR/.ready"
if HALOW_S6_CONTAINER_ENV_DIR=/tmp/_halow_fakeenv HALOW_STATUS_PORT=18097 \
        timeout 20 bash -c "$LAUNCH" > /tmp/_halow_refuse.log 2>&1; then rf=0; else rf=$?; fi
check "with a readable token file the launcher does not start the server (rc $rf)" bash -c '[ "$0" -ne 0 ] && [ "$0" -ne 124 ]' "$rf"
check "and says why" grep -q "readable by the unprivileged user" /tmp/_halow_refuse.log
check "and recorded no port" test ! -e "$HALOW_RUN_DIR/status.port"
check "and prepared no liveness directory" test ! -e /tmp/_halow_hb
chmod 0700 /tmp/_halow_fakeenv; chmod 0600 /tmp/_halow_fakeenv/SUPERVISOR_TOKEN
rm -f "$HALOW_RUN_DIR/status.port"

echo "-- with the ready file and private tokens: the launcher drops to the status user --"
(
    export HALOW_S6_CONTAINER_ENV_DIR=/tmp/_halow_fakeenv
    # shellcheck source=/dev/null
    . /usr/lib/halow/constants.sh
    # shellcheck source=/dev/null
    . /usr/lib/halow/status/launcher.sh
    halow_status_launcher_main
) > /tmp/_halow_status.log 2>&1 &
launcher_pid=$!
pid=""
for _ in $(seq 1 50); do
    for p in /proc/[0-9]*; do
        if grep -q 'status_server.py' "$p/cmdline" 2>/dev/null; then pid="${p#/proc/}"; break; fi
    done
    [ -n "$pid" ] && break
    sleep 0.2
done
check "the status server process started" test -n "$pid"
if [ -n "$pid" ]; then
    uid="$(awk '/^Uid:/ {print $2 " " $3 " " $4 " " $5}' "/proc/$pid/status")"
    want="$(id -u halowstatus)"
    check "real, effective, saved and file uid are all the status user ($want)" test "$uid" = "$want $want $want $want"
    check "the status user is not root" test "$want" != "0"
    for c in CapEff CapPrm CapAmb; do
        v="$(awk -v k="$c:" '$1 == k {print $2}' "/proc/$pid/status")"
        check "$c is zero ($v)" test "$v" = "0000000000000000"
    done
    # Read as the status user itself: root in this container lacks the ptrace capability
    # needed to read another user's environment.
    env_text="$(s6-setuidgid halowstatus cat "/proc/$pid/environ" 2>/dev/null | tr '\0' '\n' || true)"
    check "the server's environment could be read (it holds HALOW_ or PATH entries)" grep -qE '^(PATH|HALOW_)' <<< "$env_text"
    check "the server's environment has no Supervisor token" bash -c '! grep -q "^SUPERVISOR_TOKEN=" <<< "$0"' "$env_text"
    check "control: the launcher's own environment did hold a token (so the check above can fail)" test -n "${SUPERVISOR_TOKEN:-}"
    code=""
    for _ in $(seq 1 25); do
        code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${HALOW_STATUS_PORT}/health" 2>/dev/null || true)"
        [ "$code" = "200" ] && break
        sleep 0.2
    done
    check "GET /health answers 200 ($code)" test "$code" = "200"
    post="$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:${HALOW_STATUS_PORT}/health" 2>/dev/null || true)"
    check "POST is refused with 405 ($post)" test "$post" = "405"
    check "the liveness directory is mode 700 owned by the status user" test "$(stat -c '%a %U' /tmp/_halow_hb/halow-status 2>/dev/null)" = "700 halowstatus"
    hb_ok=""
    for _ in $(seq 1 30); do [ -s /tmp/_halow_hb/halow-status/heartbeat ] && { hb_ok=1; break; }; sleep 0.2; done
    check "the server wrote its liveness counter" test -n "$hb_ok"
    check "the counter file is mode 600 owned by the status user" test "$(stat -c '%a %U' /tmp/_halow_hb/halow-status/heartbeat 2>/dev/null)" = "600 halowstatus"
    check "the counter is digits and a newline" grep -qE '^[0-9]{1,20}$' /tmp/_halow_hb/halow-status/heartbeat
    check "the launcher recorded the listening port for the liveness check ($(cat "$HALOW_RUN_DIR/status.port" 2>/dev/null))" \
        test "$(cat "$HALOW_RUN_DIR/status.port" 2>/dev/null)" = "$HALOW_STATUS_PORT"
    check "the port file is 644 root" test "$(stat -c '%a %U' "$HALOW_RUN_DIR/status.port" 2>/dev/null)" = "644 root"
    kill "$pid" 2>/dev/null || true
fi
kill "$launcher_pid" 2>/dev/null || true
wait 2>/dev/null || true

echo "-- the manager's reading of the real s6-svstat (real s6-svscan and s6-supervise, scratch services) --"
SV=/tmp/_halow_sv
rm -rf "$SV"; mkdir -p "$SV/up" "$SV/down" "$SV/unsupervised"
printf '#!/bin/sh\nexec sleep 1000\n' > "$SV/up/run"; cp "$SV/up/run" "$SV/down/run"; chmod +x "$SV/up/run" "$SV/down/run"
: > "$SV/down/down"
s6-svscan "$SV" > /tmp/_halow_svscan.log 2>&1 &
svscan_pid=$!
sleep 3
(
    . /usr/lib/halow/constants.sh
    . /usr/lib/halow/manager.sh
    set +e
    HALOW_S6_STATUS_SERVICE_DIR="$SV/up"
    if up_pid="$(_halow_mgr_status_s6_pid)"; then up_rc=0; else up_rc=$?; fi
    printf 'up_rc=%s up_pid=%s real_pid=%s\n' "$up_rc" "$up_pid" "$(s6-svstat -o pid "$SV/up")"
    HALOW_S6_STATUS_SERVICE_DIR="$SV/down"
    if _halow_mgr_status_s6_pid > /dev/null; then down_rc=0; else down_rc=$?; fi
    echo "down_rc=$down_rc"
    HALOW_S6_STATUS_SERVICE_DIR="$SV/unsupervised"
    if _halow_mgr_status_s6_pid > /dev/null; then un_rc=0; else un_rc=$?; fi
    echo "unsupervised_rc=$un_rc"
) > /tmp/_halow_parse.log 2>&1
check "an up service: the manager's parser prints exactly the pid s6 reports" \
    bash -c 'read -r a b c < /tmp/_halow_parse.log; [ "$a" = up_rc=0 ] && [ -n "${b#up_pid=}" ] && [ "${b#up_pid=}" = "${c#real_pid=}" ]'
check "a down service is not up for the manager's parser" grep -qx 'down_rc=1' /tmp/_halow_parse.log
check "a directory with no supervisor is not up for the manager's parser" grep -qx 'unsupervised_rc=1' /tmp/_halow_parse.log
plain="$(s6-svstat "$SV/up")"
check "the human-readable output is not what the manager parses (it has 'pgid')" grep -q pgid <<< "$plain"
kill "$svscan_pid" 2>/dev/null || true
wait "$svscan_pid" 2>/dev/null || true
rm -rf "$SV" /tmp/_halow_svscan.log /tmp/_halow_parse.log

echo "-- the server refuses to run as root --"
# 30 s: python under QEMU emulation on a loaded build machine can take several seconds to start.
if timeout 30 python3 /usr/lib/halow/status/status_server.py --port 18098 --bind 127.0.0.1 --allow-from 127.0.0.1 \
        --snapshot "$HALOW_RUN_DIR/status.json" > /tmp/_halow_root.log 2>&1; then rc=0; else rc=$?; fi
# 0 = it ran and exited cleanly; 124/143 = it was still serving when the timeout hit.
check "the server exits non-zero at once when started as root (rc $rc)" bash -c '[ "$0" -ne 0 ] && [ "$0" -ne 124 ] && [ "$0" -ne 143 ]' "$rc"
check "and the reason is that it refuses root (not an argument error)" grep -q "refusing to run as root" /tmp/_halow_root.log

rm -rf /tmp/_halow_notready /tmp/_halow_fakeenv /tmp/_halow_notready.log /tmp/_halow_refuse.log "$HALOW_RUN_DIR" /tmp/_halow_pycache /tmp/_halow_status.log /tmp/_halow_root.log /tmp/_halow_hb
if [ "$fails" -ne 0 ]; then echo "image_status_check: $fails FAILED"; exit 1; fi
echo "image_status_check: all passed"
