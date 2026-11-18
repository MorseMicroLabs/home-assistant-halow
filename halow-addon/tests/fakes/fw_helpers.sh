#!/usr/bin/env bash
# Test helpers for the firewall, allow-list and uplink suites: installs the fake
# iptables/ip6tables and ip commands, a small Docker-like rule set, and assertions over
# the fake's rule state and call log. Sourced after test_helpers.sh and halow_test_setup.

FW_FAKES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$FW_FAKES_DIR/fw_eval.sh"

# fw_fake_setup — fresh fake state; HALOW_IPTABLES/HALOW_IP6TABLES point at the fakes.
fw_fake_setup() {
    export HALOW_FAKE_FW_DIR="$HALOW_TEST_TMP/fakefw"
    rm -rf -- "$HALOW_FAKE_FW_DIR" "$HALOW_TEST_TMP/fakebin"
    mkdir -p -- "$HALOW_FAKE_FW_DIR" "$HALOW_TEST_TMP/fakebin"
    local n
    for n in iptables ip6tables; do
        printf '#!/bin/sh\nHALOW_FAKE_FW_NAME=%s exec bash "%s/fake_iptables" "$@"\n' "$n" "$FW_FAKES_DIR" > "$HALOW_TEST_TMP/fakebin/$n"
        chmod +x "$HALOW_TEST_TMP/fakebin/$n"
    done
    export HALOW_IPTABLES="$HALOW_TEST_TMP/fakebin/iptables"
    export HALOW_IP6TABLES="$HALOW_TEST_TMP/fakebin/ip6tables"
    unset HALOW_FAKE_FW_FAIL_MATCH HALOW_FAKE_FW_FAIL_AFTER HALOW_FAKE_FW_LOCK_HELD
    rm -f -- "$HALOW_STATE_DIR/owns/fw_filter" "$HALOW_STATE_DIR/owns/fw_nat" "$HALOW_STATE_DIR/owns/fw_created_input4" "$HALOW_STATE_DIR/owns/fw_created_input6"
    # The base-chain probe reads the fake's state through the fake nft (never the host's nft).
    export HALOW_NFT="$FW_FAKES_DIR/fake_nft"
    unset HALOW_FAKE_NFT_FAIL HALOW_FAKE_FW_XBUILTIN_NOOP
}

# fw <iptables|ip6tables> <args…> — run the fake directly for test setup and inspection
# (not logged, not counted, never failure-injected).
fw() {
    local n="$1"
    shift
    HALOW_FAKE_FW_NOLOG=1 HALOW_FAKE_FW_NAME="$n" bash "$FW_FAKES_DIR/fake_iptables" "$@"
}

# fw_docker_setup <iptables|ip6tables> <with_docker_user:yes|no> — a Docker-like rule set
# plus foreign rules and chains whose names resemble the add-on's. Truncates the log.
fw_docker_setup() {
    local n="$1" du="$2"
    if [ "$du" = "yes" ]; then
        fw "$n" -N DOCKER-USER
        fw "$n" -A DOCKER-USER -j RETURN
        fw "$n" -A FORWARD -j DOCKER-USER
    fi
    fw "$n" -A FORWARD -o hassio -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    fw "$n" -A FORWARD -i hassio ! -o hassio -j ACCEPT
    fw "$n" -A FORWARD -i hassio -o hassio -j ACCEPT
    fw "$n" -A FORWARD -o docker0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    fw "$n" -A FORWARD -i docker0 ! -o docker0 -j ACCEPT
    fw "$n" -A FORWARD -i docker0 -o docker0 -j ACCEPT
    fw "$n" -A INPUT -i lo -j ACCEPT
    # Foreign chains with similar names, hooked: must never be touched.
    fw "$n" -N HALOW-INX
    fw "$n" -A HALOW-INX -j ACCEPT
    fw "$n" -A INPUT -i eth9 -j HALOW-INX
    fw "$n" -N HALOW-FWD-OUT-OLD
    fw "$n" -A HALOW-FWD-OUT-OLD -j RETURN
    fw "$n" -A FORWARD -i eth9 -j HALOW-FWD-OUT-OLD
    if [ "$n" = "iptables" ]; then
        fw "$n" -t nat -N DOCKER
        fw "$n" -t nat -A POSTROUTING -s 172.30.32.0/23 ! -o hassio -j MASQUERADE
        fw "$n" -t nat -A PREROUTING -m addrtype --dst-type LOCAL -j DOCKER
        fw "$n" -t nat -N HALOW-NATIVE
        fw "$n" -t nat -A HALOW-NATIVE -j RETURN
    fi
    fw_log_reset
}

fw_log_reset() { : > "$HALOW_FAKE_FW_DIR/log"; rm -f -- "$HALOW_FAKE_FW_DIR/mutations"; }
fw_log() { cat "$HALOW_FAKE_FW_DIR/log" 2>/dev/null || true; }

# fw_log_first|fw_log_last <fixed text> — line number of the first/last log line that
# contains <text> (0 if none).
fw_log_first() {
    local l n=0
    while IFS= read -r l; do
        n=$((n + 1))
        case "$l" in *"$1"*) echo "$n"; return 0 ;; esac
    done < "$HALOW_FAKE_FW_DIR/log"
    echo 0
}
fw_log_last() {
    local l n=0 last=0
    while IFS= read -r l; do
        n=$((n + 1))
        case "$l" in *"$1"*) last="$n" ;; esac
    done < "$HALOW_FAKE_FW_DIR/log"
    echo "$last"
}
fw_log_count() {
    local l c=0
    while IFS= read -r l; do case "$l" in *"$1"*) c=$((c + 1)) ;; esac; done < "$HALOW_FAKE_FW_DIR/log"
    echo "$c"
}

# fw_rules <name> <table> <chain> — the chain's rule specs, one per line.
fw_rules() {
    local n="$1" t="$2" c="$3" f="$HALOW_FAKE_FW_DIR/state/$1/$2/rules.$3"
    [ -f "$f" ] && cat "$f"
    return 0
}
fw_chain_exists() { [ -f "$HALOW_FAKE_FW_DIR/state/$1/$2/rules.$3" ]; }

# fw_foreign_view <name> <table> — the -S listing without anything that names one of the
# add-on's chains (exact names), for "foreign state unchanged" comparisons.
fw_foreign_view() {
    local l
    fw "$1" -t "$2" -S | while IFS= read -r l; do
        case " $l " in
            *" HALOW-IN "*|*" HALOW-FWD-OUT "*|*" HALOW-FWD-IN "*|*" HALOW-NAT "*) ;;
            *" HALOW-IN6 "*|*" HALOW-FWD-OUT6 "*|*" HALOW-FWD-IN6 "*) ;;
            *" HALOW-PARENT "*|*" HALOW-PARENT6 "*) ;;
            *) printf '%s\n' "$l" ;;
        esac
    done
}

# assert_verdict <ACCEPT|DROP> <msg> <name> <hook> key=value…
assert_verdict() {
    local expected="$1" msg="$2" out="$HALOW_TEST_TMP/verdict.out" v
    shift 2
    HALOW_TEST_COUNT=$((HALOW_TEST_COUNT + 1))
    fw_verdict "$@" > "$out" 2>"$out.err"
    v="$(cat "$out")"
    if [ "$v" = "$expected" ]; then
        echo "  ok: $msg"
    else
        echo "  FAIL: $msg (expected $expected, got '$v'; trace: $FW_EVAL_TRACE $(cat "$out.err"))"
        HALOW_TEST_FAILURES=$((HALOW_TEST_FAILURES + 1))
    fi
}

# --- fake `ip` -----------------------------------------------------------------------
# fw_ip_fake_setup — HALOW_IP points at a fake that prints the files
# $HALOW_FAKE_IP_DIR/{route_default,addr,route}; a file fail_<key> makes it exit 1.
fw_ip_fake_setup() {
    export HALOW_FAKE_IP_DIR="$HALOW_TEST_TMP/fakeip"
    mkdir -p -- "$HALOW_FAKE_IP_DIR" "$HALOW_TEST_TMP/fakebin"
    : > "$HALOW_FAKE_IP_DIR/route_default"
    : > "$HALOW_FAKE_IP_DIR/addr"
    : > "$HALOW_FAKE_IP_DIR/route"
    cat > "$HALOW_TEST_TMP/fakebin/ip" <<'EOF'
#!/bin/sh
d="${HALOW_FAKE_IP_DIR:?}"
case "$*" in
    "-4 route show default") k=route_default ;;
    "-o -4 addr show") k=addr ;;
    "-4 route show") k=route ;;
    *) echo "fake ip: unsupported: $*" >&2; exit 2 ;;
esac
[ -e "$d/fail_$k" ] && exit 1
cat "$d/$k"
EOF
    chmod +x "$HALOW_TEST_TMP/fakebin/ip"
    export HALOW_IP="$HALOW_TEST_TMP/fakebin/ip"
}

# --- nf_tables base chains (the fake models a built-in chain that does not exist yet) ---
# fw_base_absent <iptables|ip6tables> <INPUT|…> [<table>] — the nf_tables base chain does
# not exist yet (iptables still lists it; the first insertion creates it).
fw_base_absent() {
    local n="$1" c="$2" t="${3:-filter}"
    fw "$n" -t "$t" -S >/dev/null
    : > "$HALOW_FAKE_FW_DIR/state/$n/$t/absent.$c"
}
# fw_base_present <iptables|ip6tables> <chain> [<table>] — the base chain exists.
fw_base_present() { [ ! -e "$HALOW_FAKE_FW_DIR/state/$1/${3:-filter}/absent.$2" ]; }
