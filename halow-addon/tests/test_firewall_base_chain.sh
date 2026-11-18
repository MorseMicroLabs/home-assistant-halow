#!/usr/bin/env bash
# Tests the INPUT base chain handling of firewall.sh against the fake iptables/nft: on a host
# whose nf_tables ruleset has no INPUT base chain, the first rule inserted into INPUT
# creates it. The add-on records that creation before it can happen and removes the chain
# again at rollback once nothing of its own is left in it; a base chain that already existed
# (empty, with the host's rules, with another policy) and every other host structure is
# never removed; and anything unverifiable fails closed.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh
halow_test_setup
. ./fakes/fw_helpers.sh

echo "== test_firewall_base_chain =="

BR=halow-br0
SUBNET=192.168.90.1/24
GW=192.168.90.1
UP=eth0
K4=fw_created_input4
K6=fw_created_input6

# fresh [<present4:yes|no> <present6:yes|no>] — a Docker-like host (DOCKER-USER, FORWARD
# rules) with an INPUT base chain that exists ("yes", the default) or does not exist yet
# ("no", iptables still lists it).
fresh() {
    local n
    fw_fake_setup
    for n in iptables ip6tables; do
        fw "$n" -N DOCKER-USER
        fw "$n" -A DOCKER-USER -j RETURN
        fw "$n" -A FORWARD -j DOCKER-USER
        fw "$n" -A FORWARD -i docker0 -o docker0 -j ACCEPT
    done
    fw iptables -t nat -A POSTROUTING -s 172.30.32.0/23 ! -o hassio -j MASQUERADE
    [ "${1:-yes}" = "no" ] && fw_base_absent iptables INPUT
    [ "${2:-yes}" = "no" ] && fw_base_absent ip6tables INPUT
    fw_log_reset
}
install() { halow_fw_install_filters "$BR" "$SUBNET" "$GW" "$UP" "tcp/1883"; }
fw_state() { fw_foreign_view "$1" "$2"; }

# --------------------------------------------------------------------------------------
echo "-- created by this add-on: recorded before the first insertion, removed at rollback --"
fresh no no
FOREIGN4="$(fw_foreign_view iptables filter)"
FOREIGN6="$(fw_foreign_view ip6tables filter)"
NAT4="$(fw_foreign_view iptables nat)"
assert_failure "precondition: no IPv4 INPUT base chain" fw_base_present iptables INPUT
assert_failure "precondition: no IPv6 INPUT base chain" fw_base_present ip6tables INPUT
assert_success "install succeeds" install
assert_success "the IPv4 INPUT base chain now exists (created by the first jump)" fw_base_present iptables INPUT
assert_success "the IPv6 INPUT base chain now exists" fw_base_present ip6tables INPUT
assert_success "the IPv4 creation is recorded" halow_own_check "$K4"
assert_success "the IPv6 creation is recorded" halow_own_check "$K6"
assert_eq "table=filter chain=INPUT" "$(halow_own_get "$K4")" "the record names the table and the chain"
assert_success "remove_filters succeeds" halow_fw_remove_filters
assert_failure "the IPv4 INPUT base chain is gone again" fw_base_present iptables INPUT
assert_failure "the IPv6 INPUT base chain is gone again" fw_base_present ip6tables INPUT
assert_failure "the IPv4 record is cleared" halow_own_check "$K4"
assert_failure "the IPv6 record is cleared" halow_own_check "$K6"
assert_failure "fw_filter is cleared" halow_own_check fw_filter
assert_eq "$FOREIGN4" "$(fw_foreign_view iptables filter)" "the rest of the IPv4 filter table is as before (DOCKER-USER, FORWARD untouched)"
assert_eq "$FOREIGN6" "$(fw_foreign_view ip6tables filter)" "the rest of the IPv6 filter table is as before"
assert_eq "$NAT4" "$(fw_foreign_view iptables nat)" "the nat table is as before"
assert_success "DOCKER-USER still holds its own rule" test "$(fw_rules iptables filter DOCKER-USER)" = "-j RETURN"
assert_failure "halow_fw_present finds nothing of the add-on" halow_fw_present
assert_eq "2" "$(fw_log_count ' -t filter -X INPUT')" "the chain was deleted through the iptables front end, once per family"
assert_success "removal is idempotent" halow_fw_remove_filters

echo "-- IPv6 only: an IPv6 base chain absent, the IPv4 one pre-existing --"
fresh yes no
assert_success "install" install
assert_failure "no IPv4 record (the IPv4 chain existed)" halow_own_check "$K4"
assert_success "IPv6 record" halow_own_check "$K6"
assert_success "remove" halow_fw_remove_filters
assert_success "the pre-existing IPv4 INPUT chain stays" fw_base_present iptables INPUT
assert_failure "the IPv6 one the add-on created is gone" fw_base_present ip6tables INPUT
assert_eq "0" "$(fw_log_count 'iptables -w 5 -t filter -X INPUT')" "no delete of INPUT was attempted for IPv4"

echo "-- the record exists before the chain can exist (the marker precedes the first insertion into INPUT) --"
fresh no no
WRAPLOG="$HALOW_TEST_TMP/wraplog"
: > "$WRAPLOG"
for fam in 4 6; do
    real="$HALOW_TEST_TMP/fakebin/$([ "$fam" = 4 ] && echo iptables || echo ip6tables)"
    cp "$real" "$real.real"
    cat > "$real" <<EOF
#!/bin/sh
case "\$*" in *"-I INPUT "*)
    if [ -e "$HALOW_STATE_DIR/owns/fw_created_input$fam" ]; then echo "$fam marker-first" >> "$WRAPLOG"; else echo "$fam MARKER-MISSING" >> "$WRAPLOG"; fi ;;
esac
exec "$real.real" "\$@"
EOF
    chmod +x "$real"
done
assert_success "install" install
assert_eq "4 marker-first
6 marker-first" "$(grep -v '^$' "$WRAPLOG" | sort -u)" "for both families the marker already existed when the first rule went into INPUT"
halow_fw_remove_filters >/dev/null 2>&1

echo "-- jumps are removed before the chain; the chain only once empty --"
fresh no no
install >/dev/null 2>&1
fw_log_reset
assert_success "remove" halow_fw_remove_filters
j4="$(fw_log_last 'iptables -w 5 -t filter -D INPUT')"
x4="$(fw_log_first 'iptables -w 5 -t filter -X INPUT')"
assert_success "the last IPv4 INPUT jump deletion (line $j4) precedes the INPUT deletion (line $x4)" test "$j4" -gt 0 -a "$x4" -gt "$j4"
c4="$(fw_log_last 'iptables -w 5 -t filter -X HALOW-')"
assert_success "the add-on chains are deleted (line $c4) before the INPUT base chain (line $x4)" test "$c4" -gt 0 -a "$x4" -gt "$c4"
assert_eq "0" "$(fw_log_count 'iptables -w 5 -t filter -F INPUT')" "INPUT is never flushed"

echo "-- pre-existing structures are never removed --"
fresh yes yes
install >/dev/null 2>&1
assert_failure "pre-existing empty INPUT chain (both families): no record is made" halow_own_check "$K4"
assert_failure "(IPv6)" halow_own_check "$K6"
halow_fw_remove_filters >/dev/null 2>&1
assert_success "pre-existing empty INPUT chain stays (IPv4)" fw_base_present iptables INPUT
assert_success "pre-existing empty INPUT chain stays (IPv6)" fw_base_present ip6tables INPUT
assert_eq "0" "$(fw_log_count ' -X INPUT')" "no INPUT delete was even attempted"
assert_eq "0" "$(fw_rules iptables filter INPUT | grep -c .)" "and nothing of the add-on is left in it"

fresh yes yes
fw iptables -A INPUT -i lo -j ACCEPT
fw iptables -A INPUT -p tcp --dport 22 -j ACCEPT
fw ip6tables -A INPUT -i lo -j ACCEPT
HOST_INPUT="$(fw_rules iptables filter INPUT)"
install >/dev/null 2>&1
assert_failure "INPUT with the host's own rules: no record" halow_own_check "$K4"
halow_fw_remove_filters >/dev/null 2>&1
assert_eq "$HOST_INPUT" "$(fw_rules iptables filter INPUT)" "the host's INPUT rules are exactly as before (IPv4)"
assert_eq "-i lo -j ACCEPT" "$(fw_rules ip6tables filter INPUT)" "the host's INPUT rule is exactly as before (IPv6)"
assert_success "that INPUT chain still exists" fw_base_present iptables INPUT

fresh yes yes
fw iptables -P INPUT DROP
fw ip6tables -P INPUT DROP
install >/dev/null 2>&1
assert_failure "empty INPUT chain with policy DROP: no record" halow_own_check "$K4"
halow_fw_remove_filters >/dev/null 2>&1
assert_success "INPUT with policy DROP stays" fw_base_present iptables INPUT
assert_eq "-P INPUT DROP" "$(fw iptables -S INPUT | sed -n 1p)" "its policy is unchanged"
assert_success "(IPv6)" fw_base_present ip6tables INPUT

echo "-- a recorded creation that the host has since used is released, not removed --"
fresh no no
install >/dev/null 2>&1
assert_success "recorded" halow_own_check "$K4"
fw iptables -A INPUT -p tcp --dport 22 -j ACCEPT      # the host (or a user) adds a rule while the add-on runs
fw ip6tables -P INPUT DROP                            # ... and another policy
assert_success "remove succeeds (the add-on's own part is done)" halow_fw_remove_filters
assert_success "the chain with the host's rule stays" fw_base_present iptables INPUT
assert_eq "-p tcp --dport 22 -j ACCEPT" "$(fw_rules iptables filter INPUT)" "the host's rule is the only one left"
assert_success "the chain with another policy stays" fw_base_present ip6tables INPUT
assert_eq "-P INPUT DROP" "$(fw ip6tables -S INPUT | sed -n 1p)" "its policy is unchanged"
assert_failure "the claim on the IPv4 chain is dropped (it is not blocking rollback)" halow_own_check "$K4"
assert_failure "the claim on the IPv6 chain is dropped" halow_own_check "$K6"

echo "-- crash between the record and the creation: record, no chain --"
fresh no no
halow_own_mark "$K4" "table=filter chain=INPUT"
halow_own_mark "$K6" "table=filter chain=INPUT"
assert_success "remove" halow_fw_remove_filters
assert_failure "the IPv4 record is cleared" halow_own_check "$K4"
assert_failure "the IPv6 record is cleared" halow_own_check "$K6"
assert_eq "0" "$(fw_log_count ' -X INPUT')" "no delete was issued for a chain that does not exist"
assert_failure "the chain was not created by the clean-up" fw_base_present iptables INPUT

echo "-- crash after the install: the next removal (reconcile's rollback step) removes the chain --"
fresh no no
install >/dev/null 2>&1
# The process dies here: nothing but the host and the records remain. A new process:
assert_success "records survive" test -e "$HALOW_STATE_DIR/owns/$K4"
assert_success "the removal that reconcile performs" halow_fw_remove_filters
assert_failure "chain removed" fw_base_present iptables INPUT
assert_failure "record cleared" halow_own_check "$K4"

echo "-- a retried install keeps the earlier claim --"
fresh no no
install >/dev/null 2>&1
assert_success "install again (for example once the parent interface is known)" halow_fw_install_filters "$BR" "$SUBNET" "$GW" "$UP" "tcp/1883" wlu1
assert_success "the IPv4 claim stands although the chain exists now" halow_own_check "$K4"
assert_success "remove" halow_fw_remove_filters
assert_failure "chain removed" fw_base_present iptables INPUT

echo "-- fail closed: ownership cannot be established --"
fresh no no
export HALOW_NFT="$HALOW_TEST_TMP/no-such-nft"
assert_success "install works without nft" install
assert_failure "no claim without nft (IPv4)" halow_own_check "$K4"
assert_failure "no claim without nft (IPv6)" halow_own_check "$K6"
assert_success "remove works" halow_fw_remove_filters
assert_success "the chain the add-on created implicitly is NOT removed (it cannot be shown to be its own)" fw_base_present iptables INPUT
assert_eq "0" "$(fw_log_count ' -X INPUT')" "no INPUT delete was attempted"
export HALOW_NFT="$FW_FAKES_DIR/fake_nft"
fresh no no
export HALOW_FAKE_NFT_FAIL=1
install >/dev/null 2>&1
assert_failure "an unreadable chain: no claim" halow_own_check "$K4"
halow_fw_remove_filters >/dev/null 2>&1
assert_success "...and no removal" fw_base_present iptables INPUT
unset HALOW_FAKE_NFT_FAIL

echo "-- a claim whose chain cannot be read at removal is kept and reported --"
fresh no no
install >/dev/null 2>&1
export HALOW_FAKE_NFT_FAIL=1
assert_failure "remove reports failure" halow_fw_remove_filters
unset HALOW_FAKE_NFT_FAIL
assert_success "the chain is untouched" fw_base_present iptables INPUT
assert_success "the record is kept" halow_own_check "$K4"
assert_success "fw_filter is kept" halow_own_check fw_filter
assert_success "a retry then succeeds" halow_fw_remove_filters
assert_failure "chain removed" fw_base_present iptables INPUT
assert_failure "records cleared" halow_own_check "$K4"

echo "-- failure of the deletion is reported (rollback does not claim complete) --"
fresh no no
install >/dev/null 2>&1
HALOW_FAKE_FW_FAIL_MATCH="-X INPUT" assert_failure "the delete fails: remove_filters returns 1" halow_fw_remove_filters
assert_success "the chain is still there" fw_base_present iptables INPUT
assert_success "the record is kept for a retry" halow_own_check "$K4"
assert_success "fw_filter is kept" halow_own_check fw_filter
assert_success "the retry succeeds" halow_fw_remove_filters
assert_failure "chain removed" fw_base_present iptables INPUT

echo "-- a delete that silently did nothing is not taken for success (the host is re-read) --"
fresh no no
install >/dev/null 2>&1
HALOW_FAKE_FW_XBUILTIN_NOOP=1 assert_failure "exit status 0 but the chain is still present: reported" halow_fw_remove_filters
assert_success "record kept" halow_own_check "$K4"
unset HALOW_FAKE_FW_XBUILTIN_NOOP
assert_success "retry" halow_fw_remove_filters
assert_failure "chain removed" fw_base_present iptables INPUT

echo "-- a failed install removes what it created, including the base chain --"
fresh no no
HALOW_FAKE_FW_FAIL_MATCH="-I DOCKER-USER" assert_failure "install fails at the forwarding jump" install
assert_failure "the IPv4 INPUT base chain the failed install created is gone" fw_base_present iptables INPUT
assert_failure "no record is left" halow_own_check "$K4"
assert_failure "no add-on chain is left" halow_fw_present

echo "-- iptables and nft disagree about INPUT at removal: the chain is kept, the claim dropped --"
# A stand-in nft that answers for INPUT whatever HALOW_NFT_SAY says (empty, other, absent),
# for the removal step only (IPv4; IPv6 keeps the ordinary fake); the install above it uses the
# fake that follows the iptables state.
NFT_SAY="$HALOW_TEST_TMP/nft_say"
cat > "$NFT_SAY" <<'EOS'
#!/bin/sh
# IPv6 is answered by the ordinary fake (which follows the iptables state); only IPv4 is staged.
[ "$3" = "ip6" ] && exec "$HALOW_NFT_REAL" "$@"
case "${HALOW_NFT_SAY:-}" in
    empty) printf 'table %s filter {\n\tchain INPUT {\n\t\ttype filter hook input priority filter; policy accept;\n\t}\n}\n' "$3" ;;
    other) printf 'table %s filter {\n\tchain INPUT {\n\t\ttype filter hook input priority filter; policy accept;\n\t\ttcp dport 22 accept\n\t}\n}\n' "$3" ;;
    absent) echo 'Error: No such file or directory' >&2; exit 1 ;;
    *) echo "fake: unsupported" >&2; exit 2 ;;
esac
EOS
chmod +x "$NFT_SAY"

export HALOW_NFT_REAL="$FW_FAKES_DIR/fake_nft"
fresh no no
install >/dev/null 2>&1
fw iptables -A INPUT -p tcp --dport 22 -j ACCEPT      # iptables shows a rule ...
export HALOW_NFT="$NFT_SAY" HALOW_NFT_SAY=empty       # ... while nft says "empty"
fw_log_reset
assert_success "nft empty, iptables shows a rule: remove succeeds (the add-on's part is done)" halow_fw_remove_filters
assert_success "the chain stays" fw_base_present iptables INPUT
assert_eq "-p tcp --dport 22 -j ACCEPT" "$(fw_rules iptables filter INPUT)" "the rule that iptables shows is untouched"
assert_failure "the claim is dropped" halow_own_check "$K4"
assert_eq "0" "$(fw_log_count 'iptables -w 5 -t filter -X INPUT')" "no INPUT delete was attempted for IPv4 (iptables disagreed with nft)"
export HALOW_NFT="$FW_FAKES_DIR/fake_nft"; unset HALOW_NFT_SAY
fresh no no
install >/dev/null 2>&1
fw iptables -P INPUT DROP                              # iptables shows a non-accept policy ...
export HALOW_NFT="$NFT_SAY" HALOW_NFT_SAY=empty        # ... nft says "empty accept"
fw_log_reset
assert_success "nft empty, iptables shows policy DROP: remove succeeds" halow_fw_remove_filters
assert_success "the chain stays" fw_base_present iptables INPUT
assert_eq "-P INPUT DROP" "$(fw iptables -S INPUT | sed -n 1p)" "its policy is unchanged"
assert_failure "the claim is dropped" halow_own_check "$K4"
assert_eq "0" "$(fw_log_count 'iptables -w 5 -t filter -X INPUT')" "no INPUT delete was attempted for IPv4"
export HALOW_NFT="$FW_FAKES_DIR/fake_nft"; unset HALOW_NFT_SAY
fresh no no
install >/dev/null 2>&1                                 # iptables shows an empty accept chain ...
export HALOW_NFT="$NFT_SAY" HALOW_NFT_SAY=other         # ... nft says it holds a rule
fw_log_reset
assert_success "nft other, iptables empty: remove succeeds" halow_fw_remove_filters
assert_success "the chain stays (the more cautious reading wins)" fw_base_present iptables INPUT
assert_failure "the claim is dropped" halow_own_check "$K4"
assert_eq "0" "$(fw_log_count 'iptables -w 5 -t filter -X INPUT')" "no INPUT delete was attempted for IPv4"
export HALOW_NFT="$FW_FAKES_DIR/fake_nft"; unset HALOW_NFT_SAY
fresh no no
install >/dev/null 2>&1
export HALOW_NFT="$NFT_SAY" HALOW_NFT_SAY=absent        # ... nft says it does not exist at all
fw_log_reset
assert_success "nft absent, iptables lists an empty chain: remove succeeds" halow_fw_remove_filters
assert_failure "the claim is cleared" halow_own_check "$K4"
assert_eq "0" "$(fw_log_count 'iptables -w 5 -t filter -X INPUT')" "no INPUT delete was attempted (nft said it was already gone)"
export HALOW_NFT="$FW_FAKES_DIR/fake_nft"; unset HALOW_NFT_SAY

echo "-- a failed jump removal never leads to deleting INPUT --"
fresh no no
install >/dev/null 2>&1
fw_log_reset
HALOW_FW_MAX_ITER=3 HALOW_FAKE_FW_FAIL_MATCH="-D INPUT" assert_failure "the INPUT jump cannot be deleted: remove_filters returns 1" halow_fw_remove_filters
assert_eq "0" "$(fw_log_count ' -t filter -X INPUT')" "no INPUT delete was attempted"
assert_success "the base chain is untouched" fw_base_present iptables INPUT
assert_success "the claim is kept" halow_own_check "$K4"
assert_success "fw_filter is kept" halow_own_check fw_filter
assert_success "the retry (the deletion working again) succeeds" halow_fw_remove_filters
assert_failure "chain removed" fw_base_present iptables INPUT
assert_failure "claim cleared" halow_own_check "$K4"

echo "-- a retried install keeps the earlier claim; a chain the host has used since is then released --"
fresh no no
install >/dev/null 2>&1
fw iptables -A INPUT -p tcp --dport 22 -j ACCEPT      # the host uses the chain this add-on created
assert_success "install again (for example once the parent interface is known)" halow_fw_install_filters "$BR" "$SUBNET" "$GW" "$UP" "tcp/1883" wlu1
assert_success "the earlier claim stands (the chain exists and holds a rule now)" halow_own_check "$K4"
fw_log_reset
assert_success "remove" halow_fw_remove_filters
assert_success "the chain with the host's rule is kept" fw_base_present iptables INPUT
assert_eq "-p tcp --dport 22 -j ACCEPT" "$(fw_rules iptables filter INPUT)" "the host's rule is the only one left"
assert_failure "the claim is dropped" halow_own_check "$K4"
assert_eq "0" "$(fw_log_count 'iptables -w 5 -t filter -X INPUT')" "no INPUT delete was attempted for IPv4"

echo "-- other host structures are never touched --"
fresh no no
fw iptables -N HALOW-INX
fw iptables -A HALOW-INX -j ACCEPT
install >/dev/null 2>&1
halow_fw_remove_filters >/dev/null 2>&1
assert_success "a foreign chain with a similar name survives" fw_chain_exists iptables filter HALOW-INX
assert_success "DOCKER-USER survives" fw_chain_exists iptables filter DOCKER-USER
assert_success "FORWARD keeps the host's rules" test "$(fw_rules iptables filter FORWARD | wc -l | tr -d ' ')" = "2"
assert_eq "000" "$(fw_log_count ' -X FORWARD')$(fw_log_count ' -X DOCKER-USER')$(fw_log_count ' -X POSTROUTING')" "no delete of FORWARD, DOCKER-USER or POSTROUTING is ever issued"

echo "-- rollback's accounting of the new records --"
assert_success "the rollback aggregate lists both records" grep -q '^HALOW_CORE_OWNERSHIP_KEYS_BEFORE_BACKEND=.* fw_created_input4 fw_created_input6"$' "$HALOW_LIB_DIR/rollback.sh"

echo "-- nft is read-only in the product code --"
# Every invocation of nft in rootfs/ (the bare command, "$nft" or the HALOW_NFT variable, at a
# command position or inside $( )) may only be `list chain ...` (or --version); no mutating verb
# (add, delete, flush, insert, replace, create, destroy, rename, reset) and no -f / -i / --file /
# --interactive anywhere on such a line. The chain removal stays with iptables/ip6tables.
NFT_CALL='(^|[;&|]|\$\(|[[:space:]](if|then|do|else|while|until|exec|command|!)[[:space:]]+|:-)[[:space:]]*"?(nft|\$nft|\$\{nft\}|\$\{HALOW_NFT[^}]*\})"?[[:space:]]'
NFT_MUTATE='[[:space:]](add|delete|flush|insert|replace|create|destroy|rename|reset|monitor|import|export|-f|-i|--file|--interactive|-j|--json)([[:space:]]|$)'
nft_scan() {   # <code> — prints every nft invocation line that is not a plain `list chain`
    local l
    while IFS= read -r l; do
        grep -qE "$NFT_CALL" <<< "$l" || continue
        grep -qE "[[:space:]]list[[:space:]]+chain[[:space:]]" <<< "$l" && ! grep -qE "$NFT_MUTATE" <<< "$l" && continue
        printf '%s\n' "$l"
    done <<< "$1"
}
neg="$(nft_scan $'    "$nft" add rule ip filter INPUT accept\n    nft -f /tmp/rules\n    out="$(${HALOW_NFT:-nft} flush ruleset)"\n    nft -i\n    nft delete chain ip filter INPUT\n    if nft list chain ip filter INPUT; then :; fi\n    out="$("$nft" list chain ip filter INPUT 2>&1)"')"
assert_eq "5" "$(grep -c . <<< "$neg")" "negative control: the scan flags five mutating or non-list calls and accepts the two list-chain calls"
CODE_NFT="$(find "$HALOW_LIB_DIR/.." "$HALOW_LIB_DIR/../../../etc" -type f 2>/dev/null | sort -u | while IFS= read -r f; do sed -E 's/^[[:space:]]*#.*$//' "$f" 2>/dev/null; done)"
assert_success "the scan sees the product's own nft call (the scan works)" grep -qE "$NFT_CALL" <<< "$CODE_NFT"
assert_eq "" "$(nft_scan "$CODE_NFT")" "no product script calls nft other than 'list chain' (no add, delete, flush, insert, replace, create, destroy, -f, -i)"
assert_eq "1" "$(grep -cE "$NFT_CALL" <<< "$CODE_NFT")" "there is exactly one nft invocation in the product code (the chain probe)"

halow_test_teardown
echo "test_firewall_base_chain: $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed"
exit $([ "$HALOW_TEST_FAILURES" -eq 0 ] && echo 0 || echo 1)
