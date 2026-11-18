#!/usr/bin/env bash
# Runs the REAL ipv6.sh functions, with the REAL BusyBox mount and umount, in a throw-away
# container that has the same relevant options as the Supervisor gives the add-on (default
# HostConfig: not privileged, Docker's default read-only /proc/sys; CapAdd SYS_ADMIN and
# NET_ADMIN) but NO host network: --network none, with dummy interfaces created inside it, so
# nothing of the host is touched. When Docker or the image is not available it prints
# "SKIPPED: <reason>" and exits 77 (a skip, not a pass; see run_tests.sh). The image is the
# product image (BusyBox mount, bash, ip) so the tools are the
# shipped ones; name another with HALOW_TEST_IPV6_IMAGE. The libraries come from this tree
# (mounted read-only), not from the image, so an older image cannot hide the current code.
#
# Nothing is left behind: the container runs with --rm and its interfaces vanish with it.
#
# What it does NOT exercise: AppArmor enforcement (the Docker host profile, if any, is the
# default one, not this add-on's), and the host's network namespace (here the container's own).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh
halow_test_setup >/dev/null 2>&1

echo "== test_ipv6_real_container =="
IMAGE="${HALOW_TEST_IPV6_IMAGE:-morse-micro-halow-ap:local}"
LIBDIR="$(cd ../rootfs/usr/lib/halow && pwd)"

# A skip is not a pass: the marker line is the standard one and the exit status is 77, which
# run_tests.sh counts and lists as skipped (and fails on with HALOW_REQUIRE_REAL=1).
skip() {
    echo "SKIPPED: $1"
    halow_test_teardown
    echo "test_ipv6_real_container: skipped (not run)"
    exit 77
}
command -v docker >/dev/null 2>&1 || skip "docker is not installed"
docker info >/dev/null 2>&1 || skip "the docker daemon is not reachable"
docker image inspect "$IMAGE" >/dev/null 2>&1 || skip "the image $IMAGE is not present (build it, or set HALOW_TEST_IPV6_IMAGE)"
# A Windows path (Git Bash) cannot be bind-mounted by a WSL docker; the library directory is
# passed as a path the docker client can use, or the test is skipped.
case "$LIBDIR" in [A-Za-z]:*|/[a-z]/*) [ -d /mnt/c ] && LIBDIR="/mnt$LIBDIR" ;; esac
[ -d "$LIBDIR" ] || skip "the library directory is not reachable for docker"

INNER="$HALOW_TEST_TMP/inner.sh"
cat > "$INNER" <<'EOS'
#!/usr/bin/env bash
set -u
export HALOW_STATE_DIR=/tmp/halow_state
mkdir -p "$HALOW_STATE_DIR"
for lib in constants common ownership validate ipv6; do . "/halowlib/$lib.sh"; done
C=/proc/sys/net/ipv6/conf
chk() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then echo "PASS $name"; else echo "FAIL $name"; fi; }
nchk() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then echo "FAIL $name"; else echo "PASS $name"; fi; }
v() { cat "$C/$1/disable_ipv6"; }
listed() { awk -v p="$1" '$5 == p { c++ } END { print c + 0 }' /proc/self/mountinfo; }
eqv() { [ "$(v "$1")" = "$2" ]; }
wr() { { printf '%s\n' "$2" > "$1"; } 2>/dev/null; }
# ero <file> <value> — 0 when the write is refused with EROFS specifically (not another failure).
ero() { local m; m="$({ printf '%s\n' "$2" > "$1"; } 2>&1)"; case "$m" in *"Read-only file system"*) return 0 ;; esac; return 1; }
ip link add wlu1 type dummy && ip link add other0 type dummy && ip link add wlu1.sta1 type dummy || { echo "FAIL setup-interfaces"; exit 0; }
F="$C/wlu1/disable_ipv6"
echo "INFO busybox: $(busybox 2>&1 | head -n 1)"
echo "INFO proc/sys mount: $(grep ' /proc/sys ' /proc/self/mountinfo | cut -d' ' -f5-6)"

nchk "plain-write-refused-before" wr "$F" 1
chk  "plain-write-refused-with-erofs-before" ero "$F" 1
chk  "value-unchanged-after-refused-write" eqv wlu1 0

chk  "disable-through-bracket" halow_ipv6_disable wlu1
chk  "disabled-value-is-1" eqv wlu1 1
chk  "mountinfo-clean-after-disable" test "$(listed "$F")" -eq 0
nchk "write-refused-again-after-disable" wr "$F" 0
chk  "write-refused-with-erofs-after-disable" ero "$F" 0
nchk "other-file-same-interface-still-ro" wr "$C/wlu1/accept_ra" 1
nchk "other-interface-still-ro" wr "$C/other0/disable_ipv6" 1
chk  "other-interface-unchanged" eqv other0 0
nchk "all-still-ro" wr "$C/all/disable_ipv6" 1
nchk "default-still-ro" wr "$C/default/disable_ipv6" 1
chk  "all-default-unchanged" test "$(v all)$(v default)" = "00"
nchk "ip_forward-still-ro" wr /proc/sys/net/ipv4/ip_forward 0
chk  "original-recorded" test "$(halow_own_get ipv6_wlu1)" = "0"
chk  "bracket-record-cleared" test ! -e "$HALOW_STATE_DIR/owns/ipv6br_wlu1"
chk  "no-disable_ipv6-mount-anywhere" test "$(grep -c 'disable_ipv6' /proc/self/mountinfo)" -eq 0

chk  "restore-through-bracket" halow_ipv6_restore_all
chk  "restored-value-is-0" eqv wlu1 0
chk  "mountinfo-clean-after-restore" test "$(listed "$F")" -eq 0
nchk "write-refused-again-after-restore" wr "$F" 1
chk  "write-refused-with-erofs-after-restore" ero "$F" 1
chk  "records-cleared" test -z "$(ls "$HALOW_STATE_DIR/owns" 2>/dev/null)"

# all and default are refused by name; no mount is made.
nchk "disable-all-refused" halow_ipv6_disable all
nchk "disable-default-refused" halow_ipv6_disable default
chk  "no-mount-after-refusals" test "$(grep -c 'disable_ipv6' /proc/self/mountinfo)" -eq 0

# An interrupted bracket: the manager died after the write, inside the container, with the
# mount still read-write (made with the same real commands).
halow_ipv6_disable wlu1 >/dev/null 2>&1
halow_own_mark ipv6br_wlu1 ro
mount -o bind "$F" "$F" && mount -o remount,bind,rw "$F" && wr "$F" 1
chk  "stale-mount-is-listed" test "$(listed "$F")" -eq 1
chk  "stale-mount-is-writable" wr "$F" 1
chk  "restore-cleans-interrupted-bracket" halow_ipv6_restore_all
chk  "stale-mount-gone" test "$(listed "$F")" -eq 0
nchk "write-refused-after-stale-cleanup" wr "$F" 1
chk  "write-refused-with-erofs-after-stale-cleanup" ero "$F" 1
chk  "value-restored-after-stale-cleanup" eqv wlu1 0
chk  "bracket-record-cleared-after-stale-cleanup" test ! -e "$HALOW_STATE_DIR/owns/ipv6br_wlu1"

# Stacked leftovers with no record at all.
mount -o bind "$F" "$F" && mount -o remount,bind,rw "$F" && mount -o bind "$F" "$F"
chk  "two-stacked-mounts-listed" test "$(listed "$F")" -eq 2
chk  "restore-cleans-stacked-unrecorded" halow_ipv6_restore_all
chk  "stacked-mounts-gone" test "$(listed "$F")" -eq 0
nchk "write-refused-after-stacked-cleanup" wr "$F" 1
chk  "write-refused-with-erofs-after-stacked-cleanup" ero "$F" 1

# A fresh disable after the cleanups, and a disable on the per-station interface.
chk  "disable-per-station" halow_ipv6_disable wlu1.sta1
chk  "per-station-value-1" eqv wlu1.sta1 1
chk  "per-station-restore" halow_ipv6_restore_all
chk  "per-station-value-0" eqv wlu1.sta1 0
chk  "final-mount-table-clean" test "$(grep -c 'disable_ipv6' /proc/self/mountinfo)" -eq 0
echo DONE
EOS

OUTF="$HALOW_TEST_TMP/container.out"
docker run --rm -i --network none --cap-add SYS_ADMIN --cap-add NET_ADMIN \
    -v "$LIBDIR:/halowlib:ro" --entrypoint bash "$IMAGE" -s < "$INNER" > "$OUTF" 2>&1
rc=$?
grep -E '^INFO' "$OUTF" | sed 's/^/    /'
assert_eq "0" "$rc" "the container ran to its end"
assert_success "the script reached its end" grep -qx DONE "$OUTF"
assert_eq "" "$(grep -E '^FAIL' "$OUTF" || true)" "no check failed inside the container"
n_pass="$(grep -c '^PASS' "$OUTF" || true)"
assert_success "the checks ran ($n_pass passed)" test "$n_pass" -ge 40
for name in plain-write-refused-before disable-through-bracket mountinfo-clean-after-disable other-file-same-interface-still-ro \
            other-interface-still-ro all-still-ro default-still-ro restore-through-bracket restore-cleans-interrupted-bracket \
            restore-cleans-stacked-unrecorded final-mount-table-clean \
            plain-write-refused-with-erofs-before write-refused-with-erofs-after-disable write-refused-with-erofs-after-restore \
            write-refused-with-erofs-after-stale-cleanup write-refused-with-erofs-after-stacked-cleanup; do
    assert_success "check ran and passed: $name" grep -qx "PASS $name" "$OUTF"
done
if grep -q '^FAIL' "$OUTF"; then echo "---- container output ----"; cat "$OUTF"; fi

halow_test_teardown
echo "test_ipv6_real_container: $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed"
exit $([ "$HALOW_TEST_FAILURES" -eq 0 ] && echo 0 || echo 1)
