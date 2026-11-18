#!/usr/bin/env bash
# in-image check, run as the container command under the image's real
# s6-overlay /init (so s6 has saved the container environment and run /etc/cont-init.d/*
# exactly as it does for the add-on), that the unprivileged status user (uid 990) cannot
# read the Supervisor token, while root still can through with-contenv (so the root services
# keep working).
#
# Invoked by tests/verify_image.sh as (services masked so only s6 and cont-init run):
#   docker run --rm --network none --tmpfs /etc/services.d \
#       -e SUPERVISOR_TOKEN=HALOWCANARY-<random> -e HASSIO_TOKEN=HALOWCANARY-<random> \
#       -v <this file>:/tmp/image_token_check.sh:ro --entrypoint /init <image> \
#       /bin/bash /tmp/image_token_check.sh
# The canary is never passed on a command line (every user can read command lines); the
# script learns it from the container environment as root. verify_image.sh also runs it
# with /etc/cont-init.d masked, where it must FAIL (negative control).
set -u
set -o pipefail

fails=0
check() { # check <description> <command...>
    local d="$1"; shift
    if "$@"; then echo "  ok: $d"; else echo "  FAIL: $d"; fails=$((fails + 1)); fi
}
ENVDIR=/run/s6/container_environment
USER_NAME=halowstatus
# Every command run as the status user starts from an empty environment, as the real
# status server does (its launcher passes no token); otherwise this script's own
# environment would hand the token over and prove nothing.
not_contains() { [[ $1 != *"$2"* ]]; }
as_user() { env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin:/command s6-setuidgid "$USER_NAME" "$@"; }

echo "-- preconditions --"
check "this check runs as root (s6-overlay's container command)" test "$(id -u)" = "0"
check "the status user exists with uid 990" test "$(id -u "$USER_NAME" 2>/dev/null)" = "990"
canary="$(with-contenv sh -c 'printf %s "${SUPERVISOR_TOKEN:-}"')"
case "$canary" in
    HALOWCANARY-?*) echo "  ok: root reads the canary token through with-contenv (root services keep working)" ;;
    *) echo "  FAIL: root cannot read the canary token through with-contenv; the check cannot run"
       echo "image_token_check: FAILED (precondition)"; exit 1 ;;
esac
check "root also reads HASSIO_TOKEN through with-contenv" \
    test "$(with-contenv sh -c 'printf %s "${HASSIO_TOKEN:-}"')" = "$canary"
check "the container environment directory exists ($ENVDIR)" test -d "$ENVDIR"
check "control: the token file exists and root can read it" test "$(cat "$ENVDIR/SUPERVISOR_TOKEN" 2>/dev/null)" = "$canary"

echo "-- modes left by the cont-init script --"
check "$ENVDIR is 700 root ($(stat -c '%a %U' "$ENVDIR"))" test "$(stat -c '%a %U' "$ENVDIR")" = "700 root"
loose="$(find "$ENVDIR" -mindepth 1 \( ! -type f -o -perm /077 -o ! -user root \) 2>/dev/null | tr '\n' ' ')"
check "every entry is a plain file, 600 root (${loose:-none loose})" test -z "$loose"

echo "-- the status user (uid 990) cannot reach the token --"
if out="$(as_user cat "$ENVDIR/SUPERVISOR_TOKEN" 2>&1)"; then rc=0; else rc=$?; fi
check "uid 990 cannot read $ENVDIR/SUPERVISOR_TOKEN (rc $rc)" test "$rc" -ne 0
check "and its output holds no token" not_contains "$out" "$canary"
if as_user cat "$ENVDIR/HASSIO_TOKEN" >/dev/null 2>&1; then rc=0; else rc=1; fi
check "uid 990 cannot read $ENVDIR/HASSIO_TOKEN" test "$rc" -ne 0
if as_user ls "$ENVDIR" >/dev/null 2>&1; then rc=0; else rc=1; fi
check "uid 990 cannot list $ENVDIR" test "$rc" -ne 0
out="$(as_user with-contenv sh -c 'printf "%s|%s" "${SUPERVISOR_TOKEN:-}" "${HASSIO_TOKEN:-}"' 2>/dev/null || true)"
check "with-contenv run as uid 990 yields no token" not_contains "$out" "$canary"
# Every writable or state location of the image the status user can read (no /dev, /proc or
# /sys: those are checked below or hold no files).
# The scans below take the canary from a pattern file outside the scanned locations, so it
# never appears on a scanning process's own command line.
PAT=/dev/shm/_halow_token_pattern
printf '%s\n' "$canary" > "$PAT"; chmod 0644 "$PAT"
hits="$(as_user grep -rlsF -f "$PAT" /run /tmp /var /etc /opt /data /home /root /srv /mnt /usr/local /usr/lib/halow 2>/dev/null | tr '\n' ' ' || true)"
check "no file readable by uid 990 under /run /tmp /var /etc /opt /data … holds the token (${hits:-none})" test -z "$hits"
ctl="$(mktemp -d /tmp/_halow_tok.XXXXXX)"; chmod 0755 "$ctl"; printf '%s' "$canary" > "$ctl/t"; chmod 0644 "$ctl/t"
check "control: that file scan does find the token where uid 990 may read it" test -n "$(as_user grep -rlsF -f "$PAT" "$ctl" 2>/dev/null || true)"
rm -rf "$ctl"
# Every process environment and command line the status user can read.
phits="$(as_user sh -c 'for p in /proc/[0-9]*; do for f in environ cmdline; do if { tr "\0" "\n" < "$p/$f"; } 2>/dev/null | grep -F -f "$0" >/dev/null; then echo "$p/$f"; fi; done; done' "$PAT" | tr '\n' ' ' || true)"
check "no process environment or command line readable by uid 990 holds the token (${phits:-none})" test -z "$phits"
selfcmd="$(as_user cat /proc/self/cmdline 2>/dev/null | tr '\0' ' ' || true)"
check "control: uid 990 can read process data at all (its own command line: $selfcmd)" bash -c '[[ $0 == *"/proc/self/cmdline"* ]]' "$selfcmd"
rm -f "$PAT"

if [ "$fails" -ne 0 ]; then echo "image_token_check: $fails FAILED"; exit 1; fi
echo "image_token_check: all passed"
