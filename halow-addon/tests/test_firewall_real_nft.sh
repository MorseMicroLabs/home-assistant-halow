#!/usr/bin/env bash
# Real-tool test of the INPUT base chain handling of firewall.sh: the product's own firewall
# functions (halow_fw_install_filters / halow_fw_remove_filters, with the claim and release
# of the INPUT base chain) are driven against the REAL iptables-nft and the REAL nft, in a
# throwaway Docker container with its own network namespace (--network none, only
# CAP_NET_ADMIN added; never --network host, never --privileged), so nothing of the
# machine running the test is touched. The fake-based coverage is tests/test_firewall_base_chain.sh;
# this one proves that the real nft's output feeds the real parsing.
#
# The tools: the built image (morse-micro-halow-ap:local) when the kernel running it can use
# nf_tables from it (a native-architecture host). The image is aarch64; under user-mode
# emulation (an x86-64 machine running it through qemu) the netfilter netlink socket is not
# available, so then the same two packages at the exact pins of the Dockerfile (iptables,
# nftables) are installed into a plain Alpine image of the host's architecture
# (halow-realnft-test:<pins>; needs network access once, for the build). When neither works
# the test is SKIPPED: it prints "SKIPPED: <reason>" and exits 77 (a skip, not a pass; see
# run_tests.sh) for Docker missing, no image, no network, or a kernel without nf_tables.
#
# Run it from a Linux shell (WSL on Windows). The repository is bind-mounted with this
# shell's path, mapped for a WSL docker client when that exists, as test_ipv6_real_container.sh does;
# a Windows-style path that the docker client cannot mount makes the test skip.
#
# What it leaves behind: every container runs with --rm, so nothing of them remains. The
# fallback image halow-realnft-test:<hash of the pins> is a cached build artefact, kept on
# purpose so later runs need no network; remove it with `docker rmi` when it is not wanted.
#
# One container runs everything: this same script is run inside it with HALOW_REALNFT_INNER=1.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
HERE="$PWD"
REPO_DIR="$(cd .. && pwd)"

# ======================================================================================
# Inside the container
# ======================================================================================
if [ "${HALOW_REALNFT_INNER:-}" = "1" ]; then
    . ./test_helpers.sh
    halow_test_setup
    echo "== test_firewall_real_nft (inside the container: $(nft --version); $(iptables --version); $(ip6tables --version)) =="

    PARTIAL_SKIPS=0
    BR=halow-br0
    SUBNET=192.168.90.1/24
    GW=192.168.90.1
    UP=eth0
    K4=fw_created_input4
    K6=fw_created_input6
    unset HALOW_NFT HALOW_IPTABLES HALOW_IP6TABLES   # the real tools, found on PATH

    # fresh — an empty ruleset, then a Docker-like host: the filter tables exist (FORWARD
    # base chain, DOCKER-USER), but there is no INPUT base chain, as on Home Assistant OS.
    fresh() {
        local t
        nft flush ruleset
        rm -f -- "$HALOW_STATE_DIR/owns/"* 2>/dev/null
        for t in iptables ip6tables; do
            "$t" -w 5 -N DOCKER-USER
            "$t" -w 5 -A DOCKER-USER -j RETURN
            "$t" -w 5 -A FORWARD -j DOCKER-USER
            "$t" -w 5 -A FORWARD -i docker0 -o docker0 -j ACCEPT
        done
        iptables -w 5 -t nat -A POSTROUTING -s 172.30.32.0/23 ! -o hassio -j MASQUERADE
    }
    # install — no allow-list entries; install_entries — with entries (the rules carrying them,
    # --ctstate DNAT in HALOW-FWD-OUT, were once rejected by the real tool as --ctstatus DNAT).
    install() { halow_fw_install_filters "$BR" "$SUBNET" "$GW" "$UP" ""; }
    install_entries() { halow_fw_install_filters "$BR" "$SUBNET" "$GW" "$UP" "tcp/1883 udp/5683"; }
    has_input() { nft list chain "$1" filter INPUT >/dev/null 2>&1; }   # $1: ip | ip6
    ruleset() { nft list ruleset 2>&1 | grep -v '^# Warning'; }

    echo "-- real nft output feeds the real parsing --"
    fresh
    assert_failure "precondition: no ip INPUT base chain" has_input ip
    assert_failure "precondition: no ip6 INPUT base chain" has_input ip6
    assert_eq "absent" "$(_halow_fw_input_state 4)" "an absent chain is read as absent (IPv4)"
    assert_eq "absent" "$(_halow_fw_input_state 6)" "an absent chain is read as absent (IPv6)"
    iptables -w 5 -S INPUT >/dev/null; ip6tables -w 5 -S INPUT >/dev/null     # listing creates nothing
    assert_failure "listing INPUT through iptables does not create the base chain" has_input ip
    iptables -w 5 -P INPUT ACCEPT
    ip6tables -w 5 -P INPUT ACCEPT
    echo "     real: $(nft list chain ip filter INPUT 2>&1 | tr -s '\n\t ' ' ')"
    assert_eq "empty" "$(_halow_fw_input_state 4)" "an empty accept base chain is read as empty (IPv4)"
    assert_eq "empty" "$(_halow_fw_input_state 6)" "an empty accept base chain is read as empty (IPv6)"
    iptables -w 5 -A INPUT -i lo -j ACCEPT
    ip6tables -w 5 -P INPUT DROP
    assert_eq "other" "$(_halow_fw_input_state 4)" "a chain with a host rule is read as other (IPv4)"
    assert_eq "other" "$(_halow_fw_input_state 6)" "a chain with policy drop is read as other (IPv6)"
    assert_eq "unknown" "$(HALOW_NFT=/nonexistent/nft _halow_fw_input_state 4)" "no nft: unknown"

    echo "-- (1) created by the add-on: recorded, removed again, the ruleset is as before --"
    fresh
    BEFORE="$(ruleset)"
    assert_success "install" install
    assert_success "the real ip INPUT base chain now exists (the first jump created it)" has_input ip
    assert_success "the real ip6 INPUT base chain now exists" has_input ip6
    assert_success "the IPv4 creation is recorded" halow_own_check "$K4"
    assert_success "the IPv6 creation is recorded" halow_own_check "$K6"
    assert_success "remove_filters succeeds" halow_fw_remove_filters
    assert_failure "the ip INPUT base chain is gone" has_input ip
    assert_failure "the ip6 INPUT base chain is gone" has_input ip6
    assert_failure "the IPv4 record is cleared" halow_own_check "$K4"
    assert_failure "the IPv6 record is cleared" halow_own_check "$K6"
    assert_failure "fw_filter is cleared" halow_own_check fw_filter
    assert_eq "$BEFORE" "$(ruleset)" "the whole nft ruleset equals its pre-install state"
    assert_success "removal is idempotent" halow_fw_remove_filters

    echo "-- (2) a pre-existing empty INPUT base chain is preserved --"
    fresh
    iptables -w 5 -P INPUT ACCEPT
    ip6tables -w 5 -P INPUT ACCEPT
    iptables -w 5 -I INPUT -i lo -j ACCEPT && iptables -w 5 -D INPUT -i lo -j ACCEPT   # create it, then empty it
    ip6tables -w 5 -I INPUT -i lo -j ACCEPT && ip6tables -w 5 -D INPUT -i lo -j ACCEPT
    assert_success "precondition: the host has an empty ip INPUT base chain" has_input ip
    assert_success "precondition: the host has an empty ip6 INPUT base chain" has_input ip6
    BEFORE="$(ruleset)"
    assert_success "install" install
    assert_failure "no IPv4 record" halow_own_check "$K4"
    assert_failure "no IPv6 record" halow_own_check "$K6"
    assert_success "remove" halow_fw_remove_filters
    assert_success "the pre-existing ip INPUT chain stays" has_input ip
    assert_success "the pre-existing ip6 INPUT chain stays" has_input ip6
    assert_eq "$BEFORE" "$(ruleset)" "the nft ruleset equals its pre-install state"

    echo "-- (3) a pre-existing INPUT chain with host rules, or another policy, is preserved --"
    fresh
    iptables -w 5 -A INPUT -i lo -j ACCEPT
    iptables -w 5 -A INPUT -p tcp --dport 22 -j ACCEPT
    ip6tables -w 5 -A INPUT -i lo -j ACCEPT
    BEFORE="$(ruleset)"
    assert_success "install" install
    assert_failure "no record (rules present)" halow_own_check "$K4"
    assert_success "remove" halow_fw_remove_filters
    assert_eq "$BEFORE" "$(ruleset)" "host INPUT rules (both families): the ruleset equals its pre-install state"
    fresh
    iptables -w 5 -P INPUT DROP
    ip6tables -w 5 -P INPUT DROP
    BEFORE="$(ruleset)"
    assert_success "install" install
    assert_failure "no record (policy drop)" halow_own_check "$K4"
    assert_success "remove" halow_fw_remove_filters
    assert_eq "$BEFORE" "$(ruleset)" "empty INPUT chains with policy drop: the ruleset equals its pre-install state"
    assert_success "the policy is still drop (IPv4)" bash -c 'nft list chain ip filter INPUT | grep -q "policy drop"'

    echo "-- (4) a chain the host used after the claim is preserved --"
    fresh
    assert_success "install" install
    assert_success "recorded (IPv4)" halow_own_check "$K4"
    iptables -w 5 -A INPUT -p tcp --dport 22 -j ACCEPT      # the host adds a rule while the add-on runs
    ip6tables -w 5 -A INPUT -p tcp --dport 22 -j ACCEPT
    assert_success "remove succeeds" halow_fw_remove_filters
    assert_success "the used ip INPUT chain stays" has_input ip
    assert_success "the used ip6 INPUT chain stays" has_input ip6
    assert_success "the host's IPv4 rule is the only rule left in INPUT" test "$(iptables -w 5 -S INPUT | tr -d '\r')" = "-P INPUT ACCEPT
-A INPUT -p tcp -m tcp --dport 22 -j ACCEPT"
    assert_success "the host's IPv6 rule is the only rule left in INPUT" test "$(ip6tables -w 5 -S INPUT | tr -d '\r')" = "-P INPUT ACCEPT
-A INPUT -p tcp -m tcp --dport 22 -j ACCEPT"
    assert_failure "the IPv4 claim is dropped" halow_own_check "$K4"
    assert_failure "the IPv6 claim is dropped" halow_own_check "$K6"
    assert_failure "no add-on chain is left" halow_fw_present
    fresh
    assert_success "install (policy variant)" install
    iptables -w 5 -P INPUT DROP
    ip6tables -w 5 -P INPUT DROP
    assert_success "remove succeeds" halow_fw_remove_filters
    assert_success "an INPUT chain whose policy the host changed stays (IPv4)" has_input ip
    assert_success "...and keeps policy drop" bash -c 'nft list chain ip6 filter INPUT | grep -q "policy drop"'

    echo "-- (5) install WITH allow-list entries: every generated rule is accepted by the real tools --"
    fresh
    BEFORE="$(ruleset)"
    assert_success "install with entries (tcp/1883 udp/5683)" install_entries
    assert_success "the add-on chains are present" halow_fw_present
    for kind in IN OUT FIN; do
        n=0
        while IFS= read -r spec; do
            [ -z "$spec" ] && continue
            n=$((n + 1))
            # shellcheck disable=SC2086
            assert_success "real -C finds IPv4 $kind rule $n: $spec" iptables -w 5 -C "$(_halow_fw_name 4 "$kind")" $spec
        done <<< "$(_halow_fw_rules 4 "$kind" "$BR" "$SUBNET" "$GW" "$UP" "$(printf "tcp/1883
udp/5683")")"
        assert_success "real ip6tables -C finds the IPv6 $kind rule" ip6tables -w 5 -C "$(_halow_fw_name 6 "$kind")" -j DROP
    done
    OUT_LIST="$(iptables -w 5 -S "$(_halow_fw_name 4 OUT)")"
    assert_success "HALOW-FWD-OUT lists the tcp DNAT rule" grep -q -e '-p tcp -m conntrack --ctstate DNAT --ctorigdst 192.168.90.1 --ctorigdstport 1883 -j ACCEPT' <<< "$OUT_LIST"
    assert_success "HALOW-FWD-OUT lists the udp DNAT rule" grep -q -e '-p udp -m conntrack --ctstate DNAT --ctorigdst 192.168.90.1 --ctorigdstport 5683 -j ACCEPT' <<< "$OUT_LIST"
    assert_failure "no listed rule uses --ctstatus" grep -q -e ctstatus <<< "$OUT_LIST"
    assert_success "a second install with entries is idempotent" install_entries
    assert_success "remove_filters succeeds" halow_fw_remove_filters
    assert_failure "no add-on chain is left" halow_fw_present
    assert_eq "$BEFORE" "$(ruleset)" "the ruleset equals its pre-install state (entries removed again)"


    echo "-- (6) install WITH a parent interface: the catch-all jumps, real -C at INPUT 2 and the hook position 3 --"
    PARENT=wlu1
    install_parent() { halow_fw_install_filters "$BR" "$SUBNET" "$GW" "$UP" "tcp/1883" "$PARENT"; }
    fresh
    BEFORE="$(ruleset)"
    assert_success "install with a parent interface" install_parent
    for fam in 4 6; do
        if [ "$fam" = 4 ]; then T=iptables; else T=ip6tables; fi
        PC="$(_halow_fw_name "$fam" PAR)"
        assert_success "real $T -C finds INPUT -i ${PARENT}+ -j $PC" "$T" -w 5 -C INPUT -i "${PARENT}+" -j "$PC"
        assert_success "real $T -C finds DOCKER-USER -i ${PARENT}+ -j $PC" "$T" -w 5 -C DOCKER-USER -i "${PARENT}+" -j "$PC"
        assert_eq "-A INPUT -i ${PARENT}+ -j $PC" "$("$T" -w 5 -S INPUT | sed -n '3p' | tr -d '\r')" "$T: the catch-all is INPUT position 2 (listing line 3 after -P and rule 1)"
        assert_eq "-A DOCKER-USER -i ${PARENT}+ -j $PC" "$("$T" -w 5 -S DOCKER-USER | sed -n '4p' | tr -d '\r')" "$T: the catch-all is hook position 3 (after -N, FWD-OUT, FWD-IN)"
        assert_success "$T: the parent chain exists" "$T" -w 5 -S "$PC"
    done
    assert_success "the add-on chains are present" halow_fw_present
    assert_success "a second install with a parent is idempotent" install_parent
    assert_eq "1" "$(iptables -w 5 -S INPUT | grep -c -e "-i ${PARENT}+ -j HALOW-PARENT")" "exactly one IPv4 catch-all jump after the reinstall"
    assert_success "remove_filters succeeds" halow_fw_remove_filters
    assert_failure "no add-on chain is left" halow_fw_present
    assert_eq "$BEFORE" "$(ruleset)" "the ruleset equals its pre-install state (parent catch-all removed again)"

    echo "-- (7) NAT chain: real halow_fw_install_nat / halow_fw_remove_nat --"
    fresh
    if ! iptables -w 5 -t nat -S POSTROUTING >/dev/null 2>&1; then
        echo "SKIPPED (part): NAT chain section - the nat table cannot be listed in this container: $(iptables -w 5 -t nat -S POSTROUTING 2>&1 | head -n 1)"
        PARTIAL_SKIPS=$((PARTIAL_SKIPS + 1))
    else
        BEFORE="$(ruleset)"
        NATC="$(_halow_fw_name 4 NAT)"
        assert_failure "install_nat is refused before the forwarding jumps exist" halow_fw_install_nat "$BR" "$SUBNET" "$UP"
        assert_success "install filters first" install
        assert_success "install_nat succeeds against the real tools" halow_fw_install_nat "$BR" "$SUBNET" "$UP"
        assert_success "real -C finds the POSTROUTING jump" iptables -w 5 -t nat -C POSTROUTING -j "$NATC"
        assert_eq "-A POSTROUTING -j $NATC" "$(iptables -w 5 -t nat -S POSTROUTING | sed -n '2p' | tr -d '\r')" "the NAT jump is POSTROUTING position 1"
        assert_success "real -C finds the MASQUERADE rule" iptables -w 5 -t nat -C "$NATC" -s 192.168.90.0/24 -o "$UP" -j MASQUERADE
        assert_failure "the transient RETURN rebuild guard is not left in the chain" iptables -w 5 -t nat -C "$NATC" -j RETURN
        assert_eq "-N $NATC
-A $NATC -s 192.168.90.0/24 -o $UP -j MASQUERADE" "$(iptables -w 5 -t nat -S "$NATC" | tr -d '\r')" "the NAT chain holds exactly the MASQUERADE rule"
        assert_success "the NAT marker is recorded" halow_own_check fw_nat
        assert_success "a second install_nat is idempotent" halow_fw_install_nat "$BR" "$SUBNET" "$UP"
        assert_failure "no RETURN guard is left after the rebuild either" iptables -w 5 -t nat -C "$NATC" -j RETURN
        assert_eq "1" "$(iptables -w 5 -t nat -S POSTROUTING | grep -c -e "-j $NATC")" "exactly one NAT jump after the reinstall"
        assert_success "the add-on's NAT chain is recognised" halow_fw_present
        assert_success "remove_nat succeeds" halow_fw_remove_nat
        assert_failure "the NAT chain is gone" iptables -w 5 -t nat -S "$NATC"
        assert_failure "the NAT marker is cleared" halow_own_check fw_nat
        assert_success "remove_nat is idempotent" halow_fw_remove_nat
        assert_success "remove_filters succeeds" halow_fw_remove_filters
        assert_eq "$BEFORE" "$(ruleset)" "the ruleset equals its pre-install state (NAT and filters removed)"
    fi
    echo "     partial skips in this run: $PARTIAL_SKIPS"

    halow_test_teardown
    echo "test_firewall_real_nft (container): $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed (partial skips: $PARTIAL_SKIPS)"
    exit $([ "$HALOW_TEST_FAILURES" -eq 0 ] && echo 0 || echo 1)
fi

# ======================================================================================
# Outside: choose the image, run the container
# ======================================================================================
skip() { echo "SKIPPED: $*"; echo "test_firewall_real_nft: skipped (not run)"; exit 77; }

command -v docker >/dev/null 2>&1 || skip "docker is not available"
docker info >/dev/null 2>&1 || skip "the docker daemon is not reachable"

PINS="$(awk '/apk add/ {r = 1} r { line = $0; c = (line ~ /\\[[:space:]]*$/); sub(/\\[[:space:]]*$/, "", line); n = split(line, w, /[[:space:]]+/); for (i = 1; i <= n; i++) if (w[i] ~ /^(iptables|nftables)=/) printf "%s ", w[i]; if (!c) r = 0 }' "$REPO_DIR/Dockerfile")"
PINS="${PINS% }"
[ -n "$PINS" ] && [[ " $PINS " == *" nftables="* ]] && [[ " $PINS " == *" iptables="* ]] || skip "could not read the iptables and nftables pins from the Dockerfile"

# works_in <image> — can nf_tables be used from a --network none container of this image?
works_in() {
    docker run --rm --network none --cap-add NET_ADMIN --entrypoint /bin/sh "$1" -c 'nft list ruleset >/dev/null 2>&1 && iptables -w 5 -S INPUT >/dev/null 2>&1 && ip6tables -w 5 -S INPUT >/dev/null 2>&1' >/dev/null 2>&1
}

IMAGE=""
BUILT="${HALOW_IMAGE:-morse-micro-halow-ap:local}"
if docker image inspect "$BUILT" >/dev/null 2>&1 && works_in "$BUILT"; then
    IMAGE="$BUILT"
    echo "using the built image $BUILT"
else
    TAG="halow-realnft-test:$(printf '%s' "$PINS" | sha256sum | cut -c1-12)"
    if ! docker image inspect "$TAG" >/dev/null 2>&1; then
        echo "building $TAG (the pinned packages $PINS in a plain Alpine image of this machine's architecture)"
        # shellcheck disable=SC2086
        printf 'FROM alpine:3.23\nRUN apk add --no-cache bash %s\n' "$PINS" | docker build -q -t "$TAG" - >/dev/null 2>&1 \
            || skip "no usable image: $BUILT cannot use nf_tables here and $TAG could not be built (no network access, or the pins are no longer served)"
    fi
    works_in "$TAG" || skip "nf_tables (iptables-nft/nft) cannot be used from a container on this kernel"
    IMAGE="$TAG"
    echo "using $TAG ($PINS)"
fi

MOUNT_DIR="$REPO_DIR"
case "$MOUNT_DIR" in [A-Za-z]:*|/[a-z]/*) [ -d /mnt/c ] && MOUNT_DIR="/mnt$MOUNT_DIR" ;; esac
[ -d "$MOUNT_DIR" ] || skip "the repository directory is not reachable for docker (run this test from WSL or a Linux shell)"

docker run --rm --network none --cap-add NET_ADMIN --entrypoint /bin/bash \
    -v "$MOUNT_DIR:/repo:ro" -e HALOW_REALNFT_INNER=1 -w /repo/tests \
    "$IMAGE" ./test_firewall_real_nft.sh
rc=$?
echo "test_firewall_real_nft: container run rc=$rc"
exit "$rc"
