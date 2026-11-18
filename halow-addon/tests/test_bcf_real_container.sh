#!/usr/bin/env bash
# Runs the REAL kernel-log marker and board-file check (common.sh / module_load.sh) inside the
# REAL product image, against the REAL kernel log of the machine running Docker and the
# image's own BusyBox dmesg/od/wc and bash. The fake-based coverage is
# test_bcf_verification.sh; this one proves that the real dmesg output has the
# "[ seconds.micro] text" form the parser needs, that the CRC-32 computed with the image's
# own tools equals the value the driver logged on the reference device for the shipped board file, and
# that records written to the real log after a marker are found by the marker and judged
# correctly (genuine record accepted; wrong CRC, a second start without records and the
# generic "Driver loaded" record alone rejected).
#
# The records the driver would write are injected through /dev/kmsg of the Docker host's
# kernel (the container gets only that one device, plus CAP_SYSLOG for dmesg; it is not
# privileged and shares no network).
#
# HOST SIDE EFFECT (complete): this suite WRITES to the Docker host's kernel log. Per run it
# adds 10 lines to the host's /dev/kmsg: 1 probe line ("test_bcf_real_container: probe record
# (test only)") and 9 injected records, 3 of which are "morse micro driver registration ...
# TEST-ONLY" lines and 6 of which are "morse_usb 1-1:1.0: ..." records in the driver's format. Nothing is read from or
# changed on the host other than that appended text; nothing is cleared, no ring is forced
# to wrap (that would evict the host's whole log), no module is loaded, no sysctl, mount or
# network setting is touched. The lines stay in the host's kernel log until it rotates out
# or the host reboots. The wrap behaviour is covered with generated logs in
# test_bcf_verification.sh.
#
# Not a test on the reference device: the Home Assistant kernel's dmesg/CAP_SYSLOG behaviour and whether
# /dev/kmsg exists in the add-on container are not shown by this suite.
#
# When Docker, the image or /dev/kmsg is not available it prints "SKIPPED: <reason>" and
# exits 77 (a skip, not a pass; see run_tests.sh). The image is the product image (name
# another with HALOW_TEST_BCF_IMAGE).
#
# Emulation note: when the image is arm64 and the host amd64, qemu-user makes BusyBox
# dmesg's klogctl fail intermittently with EINVAL (measured: about half of the calls,
# while a native BusyBox dmesg succeeded 60 of 60). The inner script therefore retries
# dmesg a few times; this wrapper is test scaffolding only and is not in the product.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh
halow_test_setup >/dev/null 2>&1

echo "== test_bcf_real_container =="
IMAGE="${HALOW_TEST_BCF_IMAGE:-morse-micro-halow-ap:local}"
LIBDIR="$(cd ../rootfs/usr/lib/halow && pwd)"
BCFDIR="$(cd ../artifacts/bcf && pwd)"

skip() {
    echo "SKIPPED: $1"
    halow_test_teardown
    echo "test_bcf_real_container: skipped (not run)"
    exit 77
}
command -v docker >/dev/null 2>&1 || skip "docker is not installed"
docker info >/dev/null 2>&1 || skip "the docker daemon is not reachable"
docker image inspect "$IMAGE" >/dev/null 2>&1 || skip "the image $IMAGE is not present (build it, or set HALOW_TEST_BCF_IMAGE)"
case "$LIBDIR" in [A-Za-z]:*|/[a-z]/*) [ -d /mnt/c ] && LIBDIR="/mnt$LIBDIR" ;; esac
case "$BCFDIR" in [A-Za-z]:*|/[a-z]/*) [ -d /mnt/c ] && BCFDIR="/mnt$BCFDIR" ;; esac
[ -d "$LIBDIR" ] && [ -d "$BCFDIR" ] || skip "the library or board-file directory is not reachable for docker"
RUN=(docker run --rm --cap-add SYSLOG --device /dev/kmsg --entrypoint bash)
echo "  WARNING: this suite appends 10 test-injected lines (a probe and fake morse driver records, the registration ones marked TEST-ONLY) to the Docker host kernel log (/dev/kmsg); nothing is cleared."
"${RUN[@]}" "$IMAGE" -c 'dmesg >/dev/null 2>&1 || dmesg >/dev/null 2>&1 || dmesg >/dev/null 2>&1 || dmesg >/dev/null 2>&1' >/dev/null 2>&1 \
    || skip "dmesg is not readable in a container with CAP_SYSLOG on this host"
"${RUN[@]}" "$IMAGE" -c 'echo "test_bcf_real_container: probe record (test only)" > /dev/kmsg' >/dev/null 2>&1     || skip "the host's /dev/kmsg cannot be passed to a container here (records cannot be injected)"

INNER="$HALOW_TEST_TMP/inner.sh"
cat > "$INNER" <<'EOS'
#!/usr/bin/env bash
set -u
for lib in constants common module_load; do . "/halowlib/$lib.sh"; done
BCF=/bcf/bcf_boardtype_0807.bin
# test scaffolding for qemu-user (see the suite's header): retry the real BusyBox dmesg
dmesg() { local i out; for i in 1 2 3 4 5 6 7 8 9 10 11 12; do if out="$(command dmesg 2>/dev/null)"; then printf '%s\n' "$out"; return 0; fi; done; return 1; }
chk() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then echo "PASS $name"; else echo "FAIL $name"; fi; }
nchk() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then echo "FAIL $name"; else echo "PASS $name"; fi; }
k() { printf '%s\n' "$1" > /dev/kmsg; }
good_bcf='morse_usb 1-1:1.0: Loaded BCF from morse/bcf_boardtype_0807.bin, size 2510, crc32 0xc8af8c0d'
bad_bcf='morse_usb 1-1:1.0: Loaded BCF from morse/bcf_boardtype_0807.bin, size 2510, crc32 0xdeadbeef'
anchor='morse micro driver registration. Version TEST-ONLY (injected by test_bcf_real_container.sh)'
drv='morse_usb 1-1:1.0: Driver loaded with kernel module parameters'

chk "crc32-of-the-shipped-board-file-equals-the-value-the-driver-logged-on-the-reference-device" test "$(halow_crc32_file "$BCF")" = 0xc8af8c0d

m="$(halow_dmesg_watermark 2>/dev/null)"
chk "a-marker-is-taken-from-the-real-kernel-log" test -n "$m"
chk "the-marker-has-a-kernel-timestamp-in-dmesg-form" halow_klog_ts_us "$m"

# attempt 1: genuine records
k "$anchor"; k "morse_usb 1-1:1.0: Loaded firmware from morse/mm8108b2-rl.bin, size 501348, crc32 0x5152467b"; k "$good_bcf"; k "$drv"
w="$(halow_dmesg_since "$m" 2>/dev/null)"; rc=$?
chk "since-finds-the-records-after-the-marker-in-the-real-log" test "$rc" = 0
chk "the-window-holds-the-injected-Loaded-BCF-record" grep -qF "$good_bcf" <<< "$w"
chk "the-genuine-records-are-accepted" halow_check_bcf_match "$w" "$BCF"

# attempt 2: a new marker; the driver logs only the generic message
m2="$(halow_dmesg_watermark 2>/dev/null)"
k "$anchor"; k "$drv"
w2="$(halow_dmesg_since "$m2" 2>/dev/null)"
nchk "the-first-attempts-BCF-record-is-not-in-the-second-window" grep -qF "Loaded BCF" <<< "$w2"
nchk "the-generic-Driver-loaded-record-alone-is-rejected" halow_check_bcf_match "$w2" "$BCF"

# attempt 3: a different CRC-32
m3="$(halow_dmesg_watermark 2>/dev/null)"
k "$anchor"; k "$bad_bcf"; k "$drv"
w3="$(halow_dmesg_since "$m3" 2>/dev/null)"
nchk "a-board-file-record-with-a-different-CRC-32-is-rejected" halow_check_bcf_match "$w3" "$BCF"

# a marker that is not in the log (replaced log): fail closed
nchk "a-marker-that-is-not-in-the-log-fails-closed" halow_dmesg_since "[    1.000000] a record that was never written"
EOS
chmod +x "$INNER"

# stdout of the container is the result stream (PASS/FAIL lines only); stderr is kept apart
out="$("${RUN[@]}" -v "$LIBDIR:/halowlib:ro" -v "$BCFDIR:/bcf:ro" -v "$INNER:/inner.sh:ro" "$IMAGE" /inner.sh 2>"$HALOW_TEST_TMP/inner.err")"
EXPECTED_RESULTS=10
n_pass=0; n_fail=0; n_unknown=0
while IFS= read -r line; do
    case "$line" in
        "") ;;
        "PASS "*) n_pass=$((n_pass + 1)); HALOW_TEST_COUNT=$((HALOW_TEST_COUNT + 1)); echo "  ok: ${line#PASS }" ;;
        "FAIL "*) n_fail=$((n_fail + 1)); HALOW_TEST_COUNT=$((HALOW_TEST_COUNT + 1)); HALOW_TEST_FAILURES=$((HALOW_TEST_FAILURES + 1)); echo "  FAIL: ${line#FAIL }" ;;
        *) n_unknown=$((n_unknown + 1)); echo "  unexpected output line: $line" ;;
    esac
done <<< "$out"
HALOW_TEST_COUNT=$((HALOW_TEST_COUNT + 1))
if [ "$n_pass" -ne "$EXPECTED_RESULTS" ] || [ "$n_fail" -ne 0 ] || [ "$n_unknown" -ne 0 ]; then
    HALOW_TEST_FAILURES=$((HALOW_TEST_FAILURES + 1))
    echo "  FAIL: expected exactly $EXPECTED_RESULTS PASS lines and no FAIL or unknown line; got pass=$n_pass fail=$n_fail unknown=$n_unknown; stderr of the container:"
    sed 's/^/    | /' "$HALOW_TEST_TMP/inner.err"
else
    echo "  ok: exactly $EXPECTED_RESULTS result lines, all PASS, no FAIL or unknown line"
fi
halow_test_teardown
echo "test_bcf_real_container: $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed"
exit $([ "$HALOW_TEST_FAILURES" -eq 0 ] && echo 0 || echo 1)
