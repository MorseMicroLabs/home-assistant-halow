#!/usr/bin/env bash
# Runs the REAL dnsmasq binary's syntax check (`dnsmasq --test --conf-file=<file>`) on the
# configuration the product itself renders (halow_dnsmasq_write_conf), in a throw-away
# container (--network none, no added capabilities; never --network host, never
# --privileged). The fake-based coverage is tests/test_dnsmasq.sh; this one proves that the
# real dnsmasq accepts the generated option lines. --test only parses; no socket is opened.
#
# The renderer variations are the options the product accepts: the default lease (12h), each
# lease unit (s, m, h, d, bare seconds), `infinite`, and a second subnet. The product renders
# no allow-list or DNS-forwarding options into this file, so there is no further variant. A
# deliberately broken file is also checked, to show that the check can fail.
#
# A second container (NET_ADMIN added, still no network) runs the real dnsmasq on persisted
# lease files and records what dnsmasq itself does with each lease: it accepts valid and
# infinite leases, expires old ones by its own clock, and starts on a file the product has
# prepared from a damaged one.
#
# When Docker or the image is not available it prints "SKIPPED: <reason>" and exits 77 (a
# skip, not a pass; see run_tests.sh). The image is the product image (the shipped dnsmasq;
# arm64 under emulation is fine for --test); name another with HALOW_TEST_DNSMASQ_IMAGE.
# The libraries come from this tree (mounted read-only). Containers run with --rm.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh
halow_test_setup >/dev/null 2>&1

echo "== test_dnsmasq_real =="
IMAGE="${HALOW_TEST_DNSMASQ_IMAGE:-morse-micro-halow-ap:local}"
LIBDIR="$(cd ../rootfs/usr/lib/halow && pwd)"

skip() {
    echo "SKIPPED: $1"
    halow_test_teardown
    echo "test_dnsmasq_real: skipped (not run)"
    exit 77
}
command -v docker >/dev/null 2>&1 || skip "docker is not installed"
docker info >/dev/null 2>&1 || skip "the docker daemon is not reachable"
docker image inspect "$IMAGE" >/dev/null 2>&1 || skip "the image $IMAGE is not present (build it, or set HALOW_TEST_DNSMASQ_IMAGE)"
case "$LIBDIR" in [A-Za-z]:*|/[a-z]/*) [ -d /mnt/c ] && LIBDIR="/mnt$LIBDIR" ;; esac
[ -d "$LIBDIR" ] || skip "the library directory is not reachable for docker"
docker run --rm --network none --entrypoint sh "$IMAGE" -c 'command -v dnsmasq >/dev/null' >/dev/null 2>&1 \
    || skip "the image $IMAGE has no dnsmasq"

INNER="$HALOW_TEST_TMP/inner.sh"
cat > "$INNER" <<'EOS'
#!/usr/bin/env bash
set -u
export HALOW_STATE_DIR=/tmp/halow_state HALOW_RUN_DIR=/tmp/halow_run
mkdir -p "$HALOW_STATE_DIR"
for lib in constants common ownership validate dnsmasq; do . "/halowlib/$lib.sh"; done
echo "INFO $(dnsmasq --version | head -n 1)"
n=0
render_and_test() {   # <label> <bridge> <gw> <start> <end> <lease>
    local label="$1" out rc
    n=$((n + 1))
    if ! halow_dnsmasq_write_conf "$2" "$3" "$4" "$5" "$6"; then echo "FAIL render-$label"; return; fi
    sed "s/^/CONF[$label] /" "$(halow_dnsmasq_conf_file)"
    out="$(dnsmasq --test --conf-file="$(halow_dnsmasq_conf_file)" 2>&1)"; rc=$?
    echo "OUT[$label] $out"
    if [ "$rc" -eq 0 ] && grep -q 'syntax check OK' <<< "$out"; then echo "PASS syntax-$label"; else echo "FAIL syntax-$label"; fi
}
render_and_test default halow-br0 192.168.90.1 192.168.90.10 192.168.90.200 12h
render_and_test seconds halow-br0 192.168.90.1 192.168.90.10 192.168.90.200 3600
render_and_test s halow-br0 192.168.90.1 192.168.90.10 192.168.90.200 90s
render_and_test m halow-br0 192.168.90.1 192.168.90.10 192.168.90.200 30m
render_and_test d halow-br0 192.168.90.1 192.168.90.10 192.168.90.200 1d
render_and_test infinite halow-br0 192.168.90.1 192.168.90.10 192.168.90.200 infinite
render_and_test subnet2 halow-br0 10.20.30.1 10.20.30.50 10.20.30.150 12h
# The check can fail: an unknown option and a malformed range are rejected.
printf 'interface=halow-br0\nno-such-option=1\n' > /tmp/bad1.conf
if dnsmasq --test --conf-file=/tmp/bad1.conf >/dev/null 2>&1; then echo "FAIL rejects-unknown-option"; else echo "PASS rejects-unknown-option"; fi
printf 'dhcp-range=not-an-address,192.168.90.200,12h\n' > /tmp/bad2.conf
if dnsmasq --test --conf-file=/tmp/bad2.conf >/dev/null 2>&1; then echo "FAIL rejects-malformed-range"; else echo "PASS rejects-malformed-range"; fi
echo DONE
EOS

OUTF="$HALOW_TEST_TMP/container.out"
docker run --rm -i --network none \
    -v "$LIBDIR:/halowlib:ro" --entrypoint bash "$IMAGE" -s < "$INNER" > "$OUTF" 2>&1
rc=$?
grep -E '^(INFO|CONF|OUT)' "$OUTF" | sed 's/^/    /'
assert_eq "0" "$rc" "the container ran to its end"
assert_success "the script reached its end" grep -qx DONE "$OUTF"
assert_eq "" "$(grep -E '^FAIL' "$OUTF" || true)" "no check failed inside the container"
for name in default seconds s m d infinite subnet2; do
    assert_success "dnsmasq --test reports syntax check OK for the $name rendering" grep -qx "PASS syntax-$name" "$OUTF"
done
assert_success "the check can fail (unknown option rejected)" grep -qx "PASS rejects-unknown-option" "$OUTF"
assert_success "the check can fail (malformed range rejected)" grep -qx "PASS rejects-malformed-range" "$OUTF"
if grep -q '^FAIL' "$OUTF"; then echo "---- container output ----"; cat "$OUTF"; fi

# ---- persisted leases are honoured, and expired by dnsmasq's own time (second container) ----
# The real dnsmasq runs (DNS off, bound to the container's loopback, no network) with a lease
# file and a --dhcp-script that logs what dnsmasq itself does with each lease it finds at
# start: "old" for a lease it accepts, "del" for one it has expired. The only addition to the
# container's defaults is NET_ADMIN (dnsmasq refuses to run its DHCP server without it); the
# container has no network, so it can reach nothing.
INNER2="$HALOW_TEST_TMP/inner2.sh"
cat > "$INNER2" <<'EOS'
#!/usr/bin/env bash
set -u
export HALOW_STATE_DIR=/tmp/halow_state HALOW_RUN_DIR=/tmp/halow_run HALOW_LEASE_DIR=/tmp/halow_leases
mkdir -p "$HALOW_STATE_DIR" /tmp/e
for lib in constants common ownership validate dnsmasq; do . "/halowlib/$lib.sh"; done
now="$(date +%s)"
cat > /tmp/e/script.sh <<'EOT'
#!/bin/sh
echo "$1 $2 $3" >> /tmp/e/script.log
EOT
chmod +x /tmp/e/script.sh
run_dnsmasq() {   # <lease file> -> /tmp/e/script.log and /tmp/e/dm.log
    : > /tmp/e/script.log
    cat > /tmp/e/dm.conf <<EOC
interface=lo
bind-interfaces
listen-address=127.0.0.1
port=0
dhcp-range=192.168.90.10,192.168.90.200,12h
dhcp-ignore-names
dhcp-leasefile=$1
dhcp-script=/tmp/e/script.sh
EOC
    timeout 4 dnsmasq --conf-file=/tmp/e/dm.conf --no-daemon > /tmp/e/dm.log 2>&1
    echo "RC[$2] $?"
}
expect() {   # <label> <pattern> <file>
    if grep -qE -- "$2" "$3"; then echo "PASS $1"; else echo "FAIL $1"; fi
}
expect_not() {
    if grep -qE -- "$2" "$3"; then echo "FAIL $1"; else echo "PASS $1"; fi
}

# 1. A persisted file as the product keeps it (what dnsmasq itself wrote earlier).
mkdir -p "$HALOW_LEASE_DIR"
F="$HALOW_LEASE_DIR/dnsmasq.leases"
cat > "$F" <<EOF
$((now + 3600)) 02:00:00:00:00:11 192.168.90.51 * *
$((now - 100)) 02:00:00:00:00:12 192.168.90.52 * *
0 02:00:00:00:00:13 192.168.90.53 * *
EOF
run_dnsmasq "$F" raw
expect raw-started "IP range 192.168.90.10 -- 192.168.90.200" /tmp/e/dm.log
expect raw-valid-lease-found "^old 02:00:00:00:00:11 192.168.90.51$" /tmp/e/script.log
expect raw-infinite-lease-found "^old 02:00:00:00:00:13 192.168.90.53$" /tmp/e/script.log
expect raw-expired-by-dnsmasq "^del 02:00:00:00:00:12 192.168.90.52$" /tmp/e/script.log
expect_not raw-expired-not-kept-by-dnsmasq "02:00:00:00:00:12" "$F"
# 2. Restart: the file dnsmasq wrote is read again (an add-on restart).
run_dnsmasq "$F" again
expect again-valid-lease-found "^old 02:00:00:00:00:11 192.168.90.51$" /tmp/e/script.log
expect again-infinite-lease-found "^old 02:00:00:00:00:13 192.168.90.53$" /tmp/e/script.log
# 3. The product's own preparation of a damaged file, then the real dnsmasq on the result.
cat > "$F" <<EOF
$((now + 3600)) 02:00:00:00:00:21 192.168.90.61 laptop 01:02:00:00:00:21
$((now - 100)) 02:00:00:00:00:22 192.168.90.62 expired *
$((now + 3600)) 02:00:00:00:00:24 192.168.91.64 outside-the-range *
this is not a lease line
$((now + 3600)) zz:00:00:00:00:25 192.168.90.65 bad *
$((now + 3600)) 02:00:00:00:00:26 192.168.90.999 bad *
duid 00:01:00:01:aa:bb:cc:dd:ee:ff:00:11:22:33
EOF
printf '\000\001\002 garbage \377\376\n' >> "$F"
_halow_dnsmasq_prepare_leases 192.168.90.10 192.168.90.200
echo "INFO prepared file: $(halow_dhcp_lease_file) $(wc -l < "$(halow_dhcp_lease_file)") line(s)"
expect prepare-kept-valid-lease "^$((now + 3600)) 02:00:00:00:00:21 192.168.90.61 \* 01:02:00:00:00:21$" "$(halow_dhcp_lease_file)"
expect_not prepare-no-hostname "laptop" "$(halow_dhcp_lease_file)"
echo "INFO lease directory mode: $(stat -c %a "$HALOW_LEASE_DIR")"
# An expired lease appended after the preparation makes dnsmasq expire it and rewrite the
# file in place, as the product runs it (dnsmasq is started with --no-daemon and stays root,
# confined by the AppArmor profile), in the private (0700) directory.
echo "$((now - 50)) 02:00:00:00:00:27 192.168.90.67 * *" >> "$(halow_dhcp_lease_file)"
run_dnsmasq "$(halow_dhcp_lease_file)" prepared
expect prepared-rewritten-in-place-in-private-dir "^$((now + 3600)) 02:00:00:00:00:21 192.168.90.61 \* 01:02:00:00:00:21$" "$(halow_dhcp_lease_file)"
expect_not prepared-expired-line-removed-by-dnsmasq "02:00:00:00:00:27" "$(halow_dhcp_lease_file)"
expect prepared-started "IP range 192.168.90.10 -- 192.168.90.200" /tmp/e/dm.log
expect prepared-valid-lease-found "^old 02:00:00:00:00:21 192.168.90.61$" /tmp/e/script.log
expect_not prepared-nothing-else-found "^old 02:00:00:00:00:2[2-7]" /tmp/e/script.log
# 4. The product's configuration names the persisted file, and dnsmasq accepts it.
halow_dnsmasq_write_conf halow-br0 192.168.90.1 192.168.90.50 192.168.90.150 12h
expect conf-names-persisted-file "^dhcp-leasefile=/tmp/halow_leases/dnsmasq.leases$" "$(halow_dnsmasq_conf_file)"
expect conf-ignores-client-names "^dhcp-ignore-names$" "$(halow_dnsmasq_conf_file)"
if dnsmasq --test --conf-file="$(halow_dnsmasq_conf_file)" 2>&1 | grep -q 'syntax check OK'; then echo "PASS conf-syntax"; else echo "FAIL conf-syntax"; fi
# 5. What dnsmasq logs, and as whom it runs, with the product's own command line and
# configuration, on a veth pair inside the container (a DHCP client on one end).
ip link add veth0 type veth peer name veth1 && ip addr add 192.168.90.1/24 dev veth0 \
    && ip link set veth0 up && ip link set veth1 up && echo "PASS veth-setup" || echo "FAIL veth-setup"
run_logged() {   # <conf file> <label>: the product's command line, one DHCP client attempt
    dnsmasq --conf-file="$1" --pid-file="/tmp/e/$2.pid" --no-daemon > "/tmp/e/$2.log" 2>&1 &
    sleep 2
    echo "INFO[$2] dnsmasq $(grep '^Uid' "/proc/$(pgrep -x dnsmasq | head -n 1)/status" | tr '\t' ' ')"
    timeout 6 udhcpc -i veth1 -n -q -f > /dev/null 2>&1
    sleep 1
    pkill -x dnsmasq; wait
}
halow_dnsmasq_write_conf veth0 192.168.90.1 192.168.90.50 192.168.90.150 12h
cp "$(halow_dnsmasq_conf_file)" /tmp/e/product.conf
grep -v '^quiet-dhcp$' /tmp/e/product.conf > /tmp/e/loud.conf
run_logged /tmp/e/loud.conf loud
expect log-control-routine-dhcp-is-logged "dnsmasq-dhcp: DHCP(DISCOVER|OFFER)\(veth0\) [0-9a-f:]{17}" /tmp/e/loud.log
run_logged /tmp/e/product.conf product
expect log-product-dnsmasq-started "IP range 192.168.90.50 -- 192.168.90.150" /tmp/e/product.log
expect_not log-product-conf-logs-no-dhcp-transaction "DHCP(DISCOVER|OFFER|REQUEST|ACK)" /tmp/e/product.log
expect_not log-product-conf-routine-transactions-not-logged-with-mac "[0-9a-f]{2}(:[0-9a-f]{2}){5}" /tmp/e/product.log
# Errors and important messages are still logged (and may name a client MAC): a pool of one
# address that another client already holds.
sed -e 's/^dhcp-range=.*/dhcp-range=192.168.90.50,192.168.90.50,12h/' -e 's#^dhcp-leasefile=.*#dhcp-leasefile=/tmp/e/full.leases#' /tmp/e/product.conf > /tmp/e/full.conf
echo "$((now + 3600)) 02:aa:bb:cc:dd:ee 192.168.90.50 * *" > /tmp/e/full.leases
run_logged /tmp/e/full.conf full
expect log-product-conf-errors-still-logged "no address available" /tmp/e/full.log
 echo DONE2
EOS
OUTF2="$HALOW_TEST_TMP/container2.out"
docker run --rm -i --network none --cap-add NET_ADMIN \
    -v "$LIBDIR:/halowlib:ro" --entrypoint bash "$IMAGE" -s < "$INNER2" > "$OUTF2" 2>&1
rc2=$?
grep -E '^(INFO|RC)' "$OUTF2" | sed 's/^/    /'
assert_eq "0" "$rc2" "the second container ran to its end"
assert_success "the lease script reached its end" grep -qx DONE2 "$OUTF2"
assert_eq "" "$(grep -E '^FAIL' "$OUTF2" || true)" "no lease check failed inside the container"
for name in raw-started raw-valid-lease-found raw-infinite-lease-found raw-expired-by-dnsmasq raw-expired-not-kept-by-dnsmasq \
            again-valid-lease-found again-infinite-lease-found prepare-kept-valid-lease prepare-no-hostname \
            prepared-rewritten-in-place-in-private-dir prepared-expired-line-removed-by-dnsmasq \
            prepared-started prepared-valid-lease-found prepared-nothing-else-found \
            conf-names-persisted-file conf-ignores-client-names conf-syntax \
            veth-setup log-control-routine-dhcp-is-logged log-product-dnsmasq-started \
            log-product-conf-logs-no-dhcp-transaction log-product-conf-routine-transactions-not-logged-with-mac log-product-conf-errors-still-logged; do
    assert_success "real dnsmasq: $name" grep -qx "PASS $name" "$OUTF2"
done
if grep -q '^FAIL' "$OUTF2"; then echo "---- container 2 output ----"; cat "$OUTF2"; fi

halow_test_teardown
echo "test_dnsmasq_real: $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed"
exit $([ "$HALOW_TEST_FAILURES" -eq 0 ] && echo 0 || echo 1)
