#!/usr/bin/env bash
# Tests firewall.sh against the fake iptables/ip6tables (tests/fakes/fake_iptables): chain
# contents and order, jump positions, population before hooking (from the call log),
# rebuild behind a guard, idempotency, re-assertion, complete removal, failure paths and
# that no foreign rule, chain or built-in chain is touched.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh
halow_test_setup
. ./fakes/fw_helpers.sh

echo "== test_firewall =="

BR=halow-br0
SUBNET=192.168.90.1/24
NET=192.168.90.0/24
GW=192.168.90.1
UP=eth0

fresh() { # fresh <v4 DOCKER-USER yes|no> <v6 DOCKER-USER yes|no>
    fw_fake_setup
    fw_docker_setup iptables "$1"
    fw_docker_setup ip6tables "$2"
}

expect_rules() { # expect_rules <msg> <name> <table> <chain> <expected text>
    assert_eq "$5" "$(fw_rules "$2" "$3" "$4")" "$1"
}

EXP_IN="-d 255.255.255.255/32 -p udp -m udp --dport 67 -j ACCEPT
-d 192.168.90.1/32 -p udp -m udp --dport 67 -j ACCEPT
-d 192.168.90.1/32 -p udp -m udp --dport 53 -j ACCEPT
-d 192.168.90.1/32 -p tcp -m tcp --dport 53 -j ACCEPT
-d 192.168.90.1/32 -p icmp -m icmp --icmp-type 8 -j ACCEPT
-m conntrack --ctstate ESTABLISHED -j ACCEPT
-p icmp -m conntrack --ctstate RELATED -j ACCEPT
-d 192.168.90.1/32 -p tcp -m tcp --dport 1883 -j ACCEPT
-d 192.168.90.1/32 -p udp -m udp --dport 5683 -j ACCEPT
-j DROP"
EXP_OUT="-m conntrack --ctstate ESTABLISHED -j ACCEPT
-p icmp -m conntrack --ctstate RELATED -j ACCEPT
-o hassio -p tcp -m conntrack --ctstate DNAT --ctorigdst 192.168.90.1/32 --ctorigdstport 1883 -j ACCEPT
-o hassio -p udp -m conntrack --ctstate DNAT --ctorigdst 192.168.90.1/32 --ctorigdstport 5683 -j ACCEPT
-s 192.168.90.0/24 -o eth0 -j ACCEPT
-j DROP"
EXP_FIN="-m conntrack --ctstate ESTABLISHED -j ACCEPT
-p icmp -m conntrack --ctstate RELATED -j ACCEPT
-i hassio -m conntrack --ctstate NEW -j ACCEPT
-j DROP"

# ---------------------------------------------------------------------------------------
echo "-- install: contents, order, hooks --"
fresh yes no
FOREIGN4_BEFORE="$(fw_foreign_view iptables filter)"
FOREIGN6_BEFORE="$(fw_foreign_view ip6tables filter)"
assert_success "install_filters succeeds" halow_fw_install_filters "$BR" "$SUBNET" "$GW" "$UP" "tcp/1883 udp/5683"
assert_eq "bridge=$BR" "$(halow_own_get fw_filter)" "fw_filter marker records the bridge"
expect_rules "HALOW-IN holds exactly the selective rule set, in order" iptables filter HALOW-IN "$EXP_IN"
expect_rules "HALOW-FWD-OUT holds exactly its rule set, in order" iptables filter HALOW-FWD-OUT "$EXP_OUT"
assert_failure "regression: no generated rule uses --ctstatus (DNAT is a --ctstate value; the real iptables rejects --ctstatus DNAT)" grep -q -e "--ctstatus" <<< "$(fw_rules iptables filter HALOW-FWD-OUT)"
assert_success "the DNAT rules use --ctstate DNAT" test "$(fw_rules iptables filter HALOW-FWD-OUT | grep -c -e "--ctstate DNAT --ctorigdst")" -eq 2
expect_rules "HALOW-FWD-IN holds exactly its rule set, in order" iptables filter HALOW-FWD-IN "$EXP_FIN"
expect_rules "HALOW-IN6 is a single terminal drop" ip6tables filter HALOW-IN6 "-j DROP"
expect_rules "HALOW-FWD-OUT6 is a single terminal drop" ip6tables filter HALOW-FWD-OUT6 "-j DROP"
expect_rules "HALOW-FWD-IN6 is a single terminal drop" ip6tables filter HALOW-FWD-IN6 "-j DROP"
assert_eq "-i $BR -j HALOW-IN" "$(fw_rules iptables filter INPUT | sed -n 1p)" "INPUT rule 1 is the HALOW-IN jump"
assert_eq "-i $BR -j HALOW-FWD-OUT" "$(fw_rules iptables filter DOCKER-USER | sed -n 1p)" "DOCKER-USER rule 1 is the OUT jump"
assert_eq "-o $BR -j HALOW-FWD-IN" "$(fw_rules iptables filter DOCKER-USER | sed -n 2p)" "DOCKER-USER rule 2 is the IN jump (immediately after OUT)"
assert_eq "-j RETURN" "$(fw_rules iptables filter DOCKER-USER | sed -n 3p)" "Docker's own DOCKER-USER RETURN stays below the jumps"
assert_eq "0" "$(fw_rules iptables filter FORWARD | grep -c 'HALOW-FWD-\(OUT\|IN\)$')" "no IPv4 forwarding jump in FORWARD when DOCKER-USER exists"
assert_eq "-i $BR -j HALOW-FWD-OUT6" "$(fw_rules ip6tables filter FORWARD | sed -n 1p)" "IPv6 without DOCKER-USER: OUT6 jump at FORWARD position 1"
assert_eq "-o $BR -j HALOW-FWD-IN6" "$(fw_rules ip6tables filter FORWARD | sed -n 2p)" "IPv6: IN6 jump at FORWARD position 2"
assert_eq "-i $BR -j HALOW-IN6" "$(fw_rules ip6tables filter INPUT | sed -n 1p)" "IPv6: IN6 jump at INPUT position 1"
assert_eq "1" "$(fw_rules iptables filter INPUT | grep -c -- '-j HALOW-IN$')" "exactly one HALOW-IN jump"

for pair in "iptables HALOW-IN INPUT" "iptables HALOW-FWD-OUT DOCKER-USER" "iptables HALOW-FWD-IN DOCKER-USER" \
            "ip6tables HALOW-IN6 INPUT" "ip6tables HALOW-FWD-OUT6 FORWARD" "ip6tables HALOW-FWD-IN6 FORWARD"; do
    read -r n c h <<< "$pair"
    last_pop="$(fw_log_last "$n -w 5 -t filter -A $c ")"
    jl="$(grep -n -- "^$n -w 5 -t filter -I $h [0-9]* .*-j $c\$" "$HALOW_FAKE_FW_DIR/log" | cut -d: -f1 | sed -n 1p)"
    assert_success "$c ($n) populated completely (line $last_pop) before its jump is inserted (line ${jl:-none})" \
        test -n "$jl" -a "$last_pop" -gt 0 -a "$last_pop" -lt "${jl:-0}"
    cl="$(grep -n -- "^$n -w 5 -t filter -C $h .*-j $c\$" "$HALOW_FAKE_FW_DIR/log" | cut -d: -f1 | sed -n 1p)"
    assert_success "$c ($n): -C checked the jump absent before inserting it" test -n "$cl" -a "${cl:-0}" -lt "${jl:-0}"
done

bad_w="$(grep -v -c -- '^ip6\?tables -w 5 ' "$HALOW_FAKE_FW_DIR/log")"
assert_eq "0" "$bad_w" "every iptables/ip6tables call uses a bounded lock wait (-w 5)"
assert_eq "0" "$(grep -c -E -- ' -(F|X) (INPUT|FORWARD|OUTPUT|DOCKER-USER|PREROUTING|POSTROUTING)( |$)| -P | -F$| -X$' "$HALOW_FAKE_FW_DIR/log")" "no built-in or Docker chain is flushed or deleted, no policy changed"
assert_eq "$FOREIGN4_BEFORE" "$(fw_foreign_view iptables filter)" "IPv4 foreign rules and chains unchanged by install"
assert_eq "$FOREIGN6_BEFORE" "$(fw_foreign_view ip6tables filter)" "IPv6 foreign rules and chains unchanged by install"
assert_eq "0" "$(grep -c -E -- 'HALOW-INX|HALOW-FWD-OUT-OLD' "$HALOW_FAKE_FW_DIR/log")" "no call names a similar-looking foreign chain"

PRESENT="$(halow_fw_present)"; prc=$?
assert_eq "0" "$prc" "halow_fw_present reports presence"
assert_success "present lists the IPv4 INPUT jump" grep -q -x -F "ipv4 filter jump INPUT -> HALOW-IN" <<< "$PRESENT"
assert_success "present lists the IPv6 FORWARD IN6 jump" grep -q -x -F "ipv6 filter jump FORWARD -> HALOW-FWD-IN6" <<< "$PRESENT"
assert_failure "present does not list foreign chains" grep -q "HALOW-INX\|HALOW-FWD-OUT-OLD" <<< "$PRESENT"

# ---------------------------------------------------------------------------------------
echo "-- idempotent reinstall and rebuild behind a guard --"
STATE_BEFORE="$(fw iptables -S; fw ip6tables -S)"
fw_log_reset
assert_success "reinstall with identical arguments succeeds" halow_fw_install_filters "$BR" "$SUBNET" "$GW" "$UP" "tcp/1883 udp/5683"
assert_eq "$STATE_BEFORE" "$(fw iptables -S; fw ip6tables -S)" "reinstall leaves an identical rule set (no duplicates)"
assert_eq "0" "$(fw_log_count ' -I INPUT ')" "reinstall inserts no jump that is already in place"
assert_eq "0" "$(fw_log_count ' -N HALOW-')" "reinstall creates no chain that exists"
g="$(fw_log_first 'iptables -w 5 -t filter -I HALOW-IN 1 -j DROP')"
d="$(fw_log_first 'iptables -w 5 -t filter -D HALOW-IN ')"
a="$(fw_log_last 'iptables -w 5 -t filter -A HALOW-IN ')"
gd="$(fw_log_last 'iptables -w 5 -t filter -D HALOW-IN 1')"
assert_success "rebuild inserts the guard drop (line $g) before deleting old rules (line $d)" test "$g" -gt 0 -a "$g" -lt "$d"
assert_success "rebuild removes the guard (line $gd) only after the last new rule (line $a)" test "$a" -gt 0 -a "$a" -lt "$gd"

fw_log_reset
assert_success "reinstall with a changed allow-list succeeds" halow_fw_install_filters "$BR" "$SUBNET" "$GW" "$UP" "tcp/8123"
assert_success "new allow-list entry present in HALOW-IN" grep -q -x -F -- "-d 192.168.90.1/32 -p tcp -m tcp --dport 8123 -j ACCEPT" <<< "$(fw_rules iptables filter HALOW-IN)"
assert_failure "removed allow-list entry gone from HALOW-IN" grep -q -- "--dport 1883" <<< "$(fw_rules iptables filter HALOW-IN)"
assert_success "new allow-list entry present in HALOW-FWD-OUT" grep -q -- "--ctorigdstport 8123 -j ACCEPT" <<< "$(fw_rules iptables filter HALOW-FWD-OUT)"
assert_eq "-j DROP" "$(fw_rules iptables filter HALOW-IN | tail -n 1)" "HALOW-IN still ends in its terminal drop"
assert_eq "1" "$(fw_rules iptables filter HALOW-IN | grep -c -x -- '-j DROP')" "the rebuild guard is gone (one drop only)"
assert_eq "1" "$(fw_rules iptables filter DOCKER-USER | grep -c -- '-j HALOW-FWD-OUT$')" "still exactly one OUT jump"

# ---------------------------------------------------------------------------------------
echo "-- validation happens before any change --"
fresh yes no
assert_failure "bad bridge name rejected" halow_fw_install_filters "br;x" "$SUBNET" "$GW" "$UP" ""
assert_failure "bad subnet rejected" halow_fw_install_filters "$BR" "192.168.90.1" "$GW" "$UP" ""
assert_failure "gateway outside the subnet rejected" halow_fw_install_filters "$BR" "$SUBNET" "10.0.0.1" "$UP" ""
assert_failure "bad uplink rejected" halow_fw_install_filters "$BR" "$SUBNET" "$GW" "eth 0" ""
assert_failure "denied allow-list entry rejected" halow_fw_install_filters "$BR" "$SUBNET" "$GW" "$UP" "tcp/22"
assert_eq "" "$(fw_log)" "no iptables call was made for any invalid input"
assert_file_absent "$HALOW_STATE_DIR/owns/fw_filter" "no marker written for invalid input"
assert_success "host-form subnet is normalised" halow_fw_install_filters "$BR" "192.168.90.77/24" "$GW" "$UP" ""
assert_success "forward rule uses the network address" grep -q -x -F -- "-s 192.168.90.0/24 -o eth0 -j ACCEPT" <<< "$(fw_rules iptables filter HALOW-FWD-OUT)"
assert_eq "-d 255.255.255.255/32 -p udp -m udp --dport 67 -j ACCEPT
-d 192.168.90.1/32 -p udp -m udp --dport 67 -j ACCEPT
-d 192.168.90.1/32 -p udp -m udp --dport 53 -j ACCEPT
-d 192.168.90.1/32 -p tcp -m tcp --dport 53 -j ACCEPT
-d 192.168.90.1/32 -p icmp -m icmp --icmp-type 8 -j ACCEPT
-m conntrack --ctstate ESTABLISHED -j ACCEPT
-p icmp -m conntrack --ctstate RELATED -j ACCEPT
-j DROP" "$(fw_rules iptables filter HALOW-IN)" "empty allow-list: HALOW-IN has no host-port rule"
HALOW_HASSIO_IFACE=hassio-x halow_fw_install_filters "$BR" "$SUBNET" "$GW" "$UP" "tcp/1883"
assert_success "HALOW_HASSIO_IFACE overrides the Supervisor network interface (IN chain)" grep -q -x -F -- "-i hassio-x -m conntrack --ctstate NEW -j ACCEPT" <<< "$(fw_rules iptables filter HALOW-FWD-IN)"
assert_success "HALOW_HASSIO_IFACE overrides the Docker interface of the published-port rule" grep -q -- "^-o hassio-x -p tcp" <<< "$(fw_rules iptables filter HALOW-FWD-OUT)"

# ---------------------------------------------------------------------------------------
echo "-- removal --"
fresh yes no
halow_fw_install_filters "$BR" "$SUBNET" "$GW" "$UP" "tcp/1883"
FOREIGN4_BEFORE="$(fw_foreign_view iptables filter)"
fw_log_reset
assert_success "remove_filters succeeds" halow_fw_remove_filters
for c in HALOW-IN HALOW-FWD-OUT HALOW-FWD-IN; do
    assert_failure "IPv4 chain $c absent" fw_chain_exists iptables filter "$c"
done
for c in HALOW-IN6 HALOW-FWD-OUT6 HALOW-FWD-IN6; do
    assert_failure "IPv6 chain $c absent" fw_chain_exists ip6tables filter "$c"
done
assert_eq "0" "$( (fw iptables -S; fw ip6tables -S) | grep -c -E -- '-j HALOW-(IN|FWD-OUT|FWD-IN)6?$')" "no jump to an add-on chain remains"
assert_file_absent "$HALOW_STATE_DIR/owns/fw_filter" "fw_filter marker cleared after confirmed removal"
assert_eq "$FOREIGN4_BEFORE" "$(fw_foreign_view iptables filter)" "foreign rules and similar-named chains survive removal"
lastjump="$(fw_log_last 'iptables -w 5 -t filter -D DOCKER-USER')"
firstflush="$(fw_log_first 'iptables -w 5 -t filter -F HALOW-')"
assert_success "every jump is deleted (line $lastjump) before any chain is flushed (line $firstflush)" test "$lastjump" -gt 0 -a "$lastjump" -lt "$firstflush"
assert_success "the deleted jump was confirmed absent with -C" test "$(fw_log_count 'iptables -w 5 -t filter -C INPUT -i halow-br0 -j HALOW-IN')" -ge 2
assert_eq "0" "$(grep -c -E -- ' -(F|X) (INPUT|FORWARD|OUTPUT|DOCKER-USER)( |$)| -F$| -X$' "$HALOW_FAKE_FW_DIR/log")" "removal flushes or deletes no built-in or Docker chain"
assert_failure "present reports nothing after removal" halow_fw_present
assert_eq "" "$(halow_fw_present)" "present prints nothing after removal"

fw_log_reset
assert_success "remove_filters is idempotent with nothing installed" halow_fw_remove_filters
assert_eq "0" "$(grep -c -E -- ' -(A|I|D|N|F|X|P|E) ' "$HALOW_FAKE_FW_DIR/log")" "idempotent removal makes no state-changing call"

echo "-- removal finds jumps wherever they are --"
fresh yes no
halow_fw_install_filters "$BR" "$SUBNET" "$GW" "$UP" ""
# A jump that moved to FORWARD, a duplicate, and a stale jump for an old bridge name.
fw iptables -I FORWARD 1 -i "$BR" -j HALOW-FWD-OUT
fw iptables -I FORWARD 3 -o "$BR" -j HALOW-FWD-IN
fw iptables -A INPUT -i "$BR" -j HALOW-IN
fw iptables -A INPUT -i old-br -j HALOW-IN
fw ip6tables -N DOCKER-USER
fw ip6tables -A DOCKER-USER -i "$BR" -j HALOW-FWD-OUT6
assert_success "remove_filters succeeds with jumps in both hook locations" halow_fw_remove_filters
assert_eq "0" "$( (fw iptables -S; fw ip6tables -S) | grep -c -E -- '-j HALOW-(IN|FWD-OUT|FWD-IN)6?$')" "jumps in FORWARD, DOCKER-USER, duplicates and stale bridge names all removed"
assert_success "IPv6 DOCKER-USER chain itself is left in place" fw_chain_exists ip6tables filter DOCKER-USER

echo "-- removal failure keeps the marker --"
fresh yes no
halow_fw_install_filters "$BR" "$SUBNET" "$GW" "$UP" ""
export HALOW_FAKE_FW_FAIL_MATCH="-X HALOW-FWD-IN6"
assert_failure "remove_filters reports an unconfirmed removal" halow_fw_remove_filters
assert_file_exists "$HALOW_STATE_DIR/owns/fw_filter" "fw_filter marker kept when removal is unconfirmed"
assert_success "present still reports the remaining chain" halow_fw_present
unset HALOW_FAKE_FW_FAIL_MATCH
assert_success "retry removes the rest" halow_fw_remove_filters
assert_file_absent "$HALOW_STATE_DIR/owns/fw_filter" "marker cleared after the confirmed retry"

fresh yes no
halow_fw_install_filters "$BR" "$SUBNET" "$GW" "$UP" ""
export HALOW_FAKE_FW_FAIL_MATCH="ip6tables -w 5 -t filter -S"
assert_failure "remove_filters fails when the IPv6 table cannot be read" halow_fw_remove_filters
assert_file_exists "$HALOW_STATE_DIR/owns/fw_filter" "marker kept when absence cannot be verified"
PRESENT="$(halow_fw_present)"; prc=$?
assert_eq "0" "$prc" "present treats an unreadable table as not confirmed absent"
assert_success "present names the unverifiable table" grep -q -x -F "ipv6 filter unverifiable" <<< "$PRESENT"
unset HALOW_FAKE_FW_FAIL_MATCH
assert_success "removal succeeds once the table is readable" halow_fw_remove_filters

# ---------------------------------------------------------------------------------------
echo "-- install failing midway --"
fresh yes no
export HALOW_FAKE_FW_FAIL_MATCH="-A HALOW-FWD-OUT6"
assert_failure "install fails when an IPv6 rule cannot be added" halow_fw_install_filters "$BR" "$SUBNET" "$GW" "$UP" ""
unset HALOW_FAKE_FW_FAIL_MATCH
assert_eq "0" "$( (fw iptables -S; fw ip6tables -S) | grep -c -E -- '(-N|-j) HALOW-(IN|FWD-OUT|FWD-IN)6?$')" "everything installed so far (IPv4 chains and jumps too) was removed"
assert_file_absent "$HALOW_STATE_DIR/owns/fw_filter" "marker cleared because the removal was confirmed"

fresh yes no
export HALOW_FAKE_FW_FAIL_MATCH="-I DOCKER-USER"
assert_failure "install fails when the forwarding jump cannot be inserted" halow_fw_install_filters "$BR" "$SUBNET" "$GW" "$UP" ""
unset HALOW_FAKE_FW_FAIL_MATCH
assert_eq "0" "$(fw iptables -S | grep -c -E -- 'HALOW-(IN|FWD-OUT|FWD-IN)$')" "INPUT jump and chains removed after the failed hook"

fresh yes no
export HALOW_FAKE_FW_FAIL_AFTER=6
assert_failure "install fails when iptables stops working midway" halow_fw_install_filters "$BR" "$SUBNET" "$GW" "$UP" ""
assert_file_exists "$HALOW_STATE_DIR/owns/fw_filter" "marker kept: the partial install could not be removed"
assert_success "present recognises the partial install from the host" halow_fw_present
assert_eq "0" "$(fw iptables -S | grep -c -- '-j HALOW-IN$')" "no jump was installed for the partially populated chain"
unset HALOW_FAKE_FW_FAIL_AFTER
assert_success "a later removal clears the residue" halow_fw_remove_filters
assert_failure "nothing left afterwards" halow_fw_present

fresh yes no
halow_fw_install_filters "$BR" "$SUBNET" "$GW" "$UP" "tcp/1883"
fw_log_reset
export HALOW_FAKE_FW_FAIL_MATCH="-A HALOW-FWD-OUT -s"
assert_failure "a failed rebuild of a hooked chain fails the install" halow_fw_install_filters "$BR" "$SUBNET" "$GW" "$UP" "tcp/1883"
unset HALOW_FAKE_FW_FAIL_MATCH
g="$(fw_log_first 'iptables -w 5 -t filter -I HALOW-FWD-OUT 1 -j DROP')"
f="$(fw_log_first 'INJECTED-FAILURE')"
assert_success "the guard drop was in place (line $g) when the rebuild failed (line $f)" test "$g" -gt 0 -a "$g" -lt "$f"
assert_failure "the failed rebuild was followed by complete removal" halow_fw_present

# ---------------------------------------------------------------------------------------
echo "-- re-assertion --"
fresh no no
halow_fw_install_filters "$BR" "$SUBNET" "$GW" "$UP" ""
assert_eq "-i $BR -j HALOW-FWD-OUT" "$(fw_rules iptables filter FORWARD | sed -n 1p)" "no DOCKER-USER: OUT jump at FORWARD position 1"
assert_eq "-o $BR -j HALOW-FWD-IN" "$(fw_rules iptables filter FORWARD | sed -n 2p)" "no DOCKER-USER: IN jump at FORWARD position 2"
fw_log_reset
assert_success "reassert with everything in place succeeds" halow_fw_reassert
assert_eq "0" "$(grep -c -E -- ' -(A|I|D|N|F|X|P|E) ' "$HALOW_FAKE_FW_DIR/log")" "reassert with everything in place changes nothing"
# A Docker restart re-inserts its rules above ours.
fw iptables -I FORWARD 1 -i docker0 -o "$BR" -j ACCEPT
fw iptables -I FORWARD 1 -o docker0 -j ACCEPT
fw_log_reset
assert_success "reassert after Docker inserted rules above ours succeeds" halow_fw_reassert
assert_eq "-i $BR -j HALOW-FWD-OUT" "$(fw_rules iptables filter FORWARD | sed -n 1p)" "OUT jump back at position 1"
assert_eq "-o $BR -j HALOW-FWD-IN" "$(fw_rules iptables filter FORWARD | sed -n 2p)" "IN jump back at position 2"
assert_eq "-o docker0 -j ACCEPT" "$(fw_rules iptables filter FORWARD | sed -n 3p)" "Docker's rules kept, below ours"
assert_eq "1" "$(fw_rules iptables filter FORWARD | grep -c -- '-j HALOW-FWD-OUT$')" "no duplicate OUT jump after reassert"
assert_eq "1" "$(fw_rules iptables filter FORWARD | grep -c -- '-j HALOW-FWD-IN$')" "no duplicate IN jump after reassert"
ins="$(fw_log_first 'iptables -w 5 -t filter -I FORWARD 1 -i halow-br0 -j HALOW-FWD-OUT')"
del="$(fw_log_first 'iptables -w 5 -t filter -D FORWARD ')"
assert_success "reassert inserts the new jump (line $ins) before deleting the stale one (line $del)" test "$ins" -gt 0 -a "$ins" -lt "$del"
assert_eq "2" "$(grep -c -E -- '-D FORWARD [0-9]+$' "$HALOW_FAKE_FW_DIR/log")" "exactly the two stale jumps were deleted, by verified rule number"
# DOCKER-USER appears later (Docker started after the add-on).
fw iptables -N DOCKER-USER
fw iptables -A DOCKER-USER -j RETURN
fw iptables -I FORWARD 1 -j DOCKER-USER
fw_log_reset
assert_success "reassert moves the jumps into a newly created DOCKER-USER" halow_fw_reassert
assert_eq "-i $BR -j HALOW-FWD-OUT
-o $BR -j HALOW-FWD-IN
-j RETURN" "$(fw_rules iptables filter DOCKER-USER)" "jumps now at DOCKER-USER positions 1 and 2"
assert_eq "0" "$(fw_rules iptables filter FORWARD | grep -c -E -- '-j HALOW-FWD-(OUT|IN)$')" "stale FORWARD jumps removed"
ins="$(fw_log_first 'iptables -w 5 -t filter -I DOCKER-USER 1')"
del="$(fw_log_first 'iptables -w 5 -t filter -D FORWARD ')"
assert_success "new location filled (line $ins) before the old is emptied (line $del)" test "$ins" -gt 0 -a "$ins" -lt "$del"
# A lost jump is re-created; a missing chain is reported, never jumped to.
fw iptables -D INPUT -i "$BR" -j HALOW-IN
assert_success "reassert re-creates a lost INPUT jump" halow_fw_reassert
assert_eq "-i $BR -j HALOW-IN" "$(fw_rules iptables filter INPUT | sed -n 1p)" "INPUT jump restored at position 1"
fw ip6tables -D FORWARD -o "$BR" -j HALOW-FWD-IN6
fw ip6tables -F HALOW-FWD-IN6
fw ip6tables -X HALOW-FWD-IN6
assert_failure "reassert reports a recorded chain that disappeared" halow_fw_reassert
assert_eq "0" "$(fw ip6tables -S | grep -c -- '-j HALOW-FWD-IN6')" "no jump to the missing chain is created"
halow_fw_remove_filters >/dev/null 2>&1
fw_log_reset
assert_success "reassert with nothing installed is a no-op" halow_fw_reassert
assert_eq "0" "$(grep -c -E -- ' -(A|I|D|N|F|X|P|E) ' "$HALOW_FAKE_FW_DIR/log")" "no state-changing call when nothing is installed"
assert_failure "reassert refuses an invalid bridge name" halow_fw_reassert "bad name"

# ---------------------------------------------------------------------------------------
echo "-- NAT chain --"
fresh yes no
NATFOREIGN="$(fw_foreign_view iptables nat)"
assert_failure "NAT is refused before the filter chains are hooked" halow_fw_install_nat "$BR" "$SUBNET" "$UP"
assert_file_absent "$HALOW_STATE_DIR/owns/fw_nat" "no fw_nat marker after the refusal"
assert_failure "no NAT chain after the refusal" fw_chain_exists iptables nat HALOW-NAT
halow_fw_install_filters "$BR" "$SUBNET" "$GW" "$UP" ""
fw_log_reset
assert_success "install_nat succeeds after the filters" halow_fw_install_nat "$BR" "$SUBNET" "$UP"
expect_rules "HALOW-NAT masquerades the HaLow subnet towards the uplink" iptables nat HALOW-NAT "-s $NET -o $UP -j MASQUERADE"
assert_eq "-j HALOW-NAT" "$(fw_rules iptables nat POSTROUTING | sed -n 1p)" "POSTROUTING rule 1 is the NAT jump"
assert_success "fw_nat marker written" test -e "$HALOW_STATE_DIR/owns/fw_nat"
a="$(fw_log_last 'iptables -w 5 -t nat -A HALOW-NAT ')"
j="$(fw_log_first 'iptables -w 5 -t nat -I POSTROUTING 1 -j HALOW-NAT')"
assert_success "HALOW-NAT populated (line $a) before its jump (line $j)" test "$a" -gt 0 -a "$a" -lt "$j"
assert_success "NAT reinstall is idempotent" halow_fw_install_nat "$BR" "$SUBNET" "$UP"
assert_eq "1" "$(fw_rules iptables nat POSTROUTING | grep -c -- '-j HALOW-NAT$')" "one NAT jump after reinstall"
assert_eq "1" "$(fw_rules iptables nat HALOW-NAT | grep -c .)" "one MASQUERADE rule after reinstall"
fw iptables -t nat -I POSTROUTING 1 -s 172.30.32.0/23 -j MASQUERADE
assert_success "reassert re-places the NAT jump" halow_fw_reassert
assert_eq "-j HALOW-NAT" "$(fw_rules iptables nat POSTROUTING | sed -n 1p)" "NAT jump back at POSTROUTING position 1"
fw iptables -t nat -D POSTROUTING 2
assert_success "remove_nat succeeds" halow_fw_remove_nat
assert_failure "HALOW-NAT absent" fw_chain_exists iptables nat HALOW-NAT
assert_eq "0" "$(fw iptables -t nat -S | grep -c -- '-j HALOW-NAT$')" "no NAT jump remains"
assert_file_absent "$HALOW_STATE_DIR/owns/fw_nat" "fw_nat marker cleared"
assert_eq "$NATFOREIGN" "$(fw_foreign_view iptables nat)" "Docker's NAT rules and the similar-named HALOW-NATIVE chain untouched"
assert_success "remove_nat is idempotent" halow_fw_remove_nat
assert_success "filters still installed after NAT removal" fw_chain_exists iptables filter HALOW-IN
fw iptables -t nat -N HALOW-NAT
fw iptables -t nat -A HALOW-NAT -j RETURN
fw iptables -t nat -A POSTROUTING -j HALOW-NAT
halow_own_mark fw_nat x
export HALOW_FAKE_FW_FAIL_MATCH="-X HALOW-NAT"
assert_failure "remove_nat reports an unconfirmed removal" halow_fw_remove_nat
assert_file_exists "$HALOW_STATE_DIR/owns/fw_nat" "fw_nat kept when unconfirmed"
assert_eq "0" "$(fw iptables -t nat -S | grep -c -- '-j HALOW-NAT$')" "the jump was still removed first"
unset HALOW_FAKE_FW_FAIL_MATCH
assert_success "remove_nat retry succeeds" halow_fw_remove_nat
export HALOW_FAKE_FW_FAIL_MATCH="-I POSTROUTING"
assert_failure "a failed NAT hook fails install_nat" halow_fw_install_nat "$BR" "$SUBNET" "$UP"
unset HALOW_FAKE_FW_FAIL_MATCH
assert_failure "and the NAT chain was removed again" fw_chain_exists iptables nat HALOW-NAT
assert_file_absent "$HALOW_STATE_DIR/owns/fw_nat" "and its marker cleared"

# ---------------------------------------------------------------------------------------
echo "-- catch-all for the radio's own interfaces (parent and per-station) --"
PAR=wlu1
fresh yes no
FOREIGN4_BEFORE="$(fw_foreign_view iptables filter)"
assert_success "install_filters with the parent interface succeeds" halow_fw_install_filters "$BR" "$SUBNET" "$GW" "$UP" "tcp/1883" "$PAR"
assert_eq "bridge=$BR
parent=$PAR" "$(halow_own_get fw_filter)" "fw_filter records the bridge and the parent"
expect_rules "HALOW-PARENT is a single terminal drop" iptables filter HALOW-PARENT "-j DROP"
expect_rules "HALOW-PARENT6 is a single terminal drop" ip6tables filter HALOW-PARENT6 "-j DROP"
assert_eq "-i $BR -j HALOW-IN
-i $PAR+ -j HALOW-PARENT" "$(fw_rules iptables filter INPUT | sed -n 1,2p)" "INPUT: the bridge jump first, the parent catch-all second"
assert_eq "-i $BR -j HALOW-FWD-OUT
-o $BR -j HALOW-FWD-IN
-i $PAR+ -j HALOW-PARENT
-j RETURN" "$(fw_rules iptables filter DOCKER-USER)" "DOCKER-USER: OUT, IN, then the parent catch-all, above Docker's RETURN"
assert_eq "-i $PAR+ -j HALOW-PARENT6" "$(fw_rules ip6tables filter INPUT | sed -n 2p)" "IPv6 INPUT position 2 is the parent catch-all"
assert_eq "-i $PAR+ -j HALOW-PARENT6" "$(fw_rules ip6tables filter FORWARD | sed -n 3p)" "IPv6 FORWARD position 3 is the parent catch-all"
for pair in "iptables HALOW-PARENT INPUT" "iptables HALOW-PARENT DOCKER-USER" "ip6tables HALOW-PARENT6 INPUT" "ip6tables HALOW-PARENT6 FORWARD"; do
    read -r n c h <<< "$pair"
    last_pop="$(fw_log_last "$n -w 5 -t filter -A $c ")"
    jl="$(grep -n -- "^$n -w 5 -t filter -I $h [0-9]* -i $PAR+ -j $c\$" "$HALOW_FAKE_FW_DIR/log" | cut -d: -f1 | sed -n 1p)"
    assert_success "$c ($n) populated (line $last_pop) before its $h jump (line ${jl:-none})" test -n "$jl" -a "$last_pop" -gt 0 -a "$last_pop" -lt "${jl:-0}"
done
assert_eq "$FOREIGN4_BEFORE" "$(fw_foreign_view iptables filter)" "foreign rules unchanged by the catch-all"
PRESENT="$(halow_fw_present)"
assert_success "present lists the catch-all chain" grep -q -x -F "ipv4 filter chain HALOW-PARENT" <<< "$PRESENT"
assert_success "present lists the IPv6 catch-all jump" grep -q -x -F "ipv6 filter jump INPUT -> HALOW-PARENT6" <<< "$PRESENT"
assert_success "the IPv6 chains count as governing IPv6" halow_fw_ipv6_governed
STATE_BEFORE="$(fw iptables -S; fw ip6tables -S)"
fw_log_reset
assert_success "reinstall with the parent is idempotent" halow_fw_install_filters "$BR" "$SUBNET" "$GW" "$UP" "tcp/1883" "$PAR"
assert_eq "$STATE_BEFORE" "$(fw iptables -S; fw ip6tables -S)" "...identical rule set"
assert_eq "0" "$(fw_log_count ' -I INPUT ')" "...no jump re-inserted"

echo "-- adding the catch-all later, and dropping it --"
fresh yes no
halow_fw_install_filters "$BR" "$SUBNET" "$GW" "$UP" "" >/dev/null 2>&1
assert_failure "no catch-all without the parent" fw_chain_exists iptables filter HALOW-PARENT
fw_log_reset
assert_success "a second install adds the catch-all once the parent is known" halow_fw_install_filters "$BR" "$SUBNET" "$GW" "$UP" "" "$PAR"
assert_eq "0" "$(grep -c -E -- '-D (INPUT|DOCKER-USER|FORWARD) ' "$HALOW_FAKE_FW_DIR/log")" "...without removing any bridge jump meanwhile (no gap)"
assert_eq "-i $PAR+ -j HALOW-PARENT" "$(fw_rules iptables filter INPUT | sed -n 2p)" "...the catch-all is hooked"
assert_success "an install without the parent removes an earlier catch-all" halow_fw_install_filters "$BR" "$SUBNET" "$GW" "$UP" ""
assert_eq "0" "$( (fw iptables -S; fw ip6tables -S) | grep -c -- 'HALOW-PARENT')" "...chains and jumps gone in both families"
assert_eq "bridge=$BR" "$(halow_own_get fw_filter)" "...and the record no longer names a parent"

echo "-- catch-all validation --"
fresh yes no
assert_failure "an invalid parent name is refused" halow_fw_install_filters "$BR" "$SUBNET" "$GW" "$UP" "" 'wl;u1'
assert_failure "the parent may not be the uplink" halow_fw_install_filters "$BR" "$SUBNET" "$GW" "$UP" "" "$UP"
assert_failure "the parent may not be the bridge" halow_fw_install_filters "$BR" "$SUBNET" "$GW" "$UP" "" "$BR"
assert_failure "a parent whose catch-all would match the uplink is refused" halow_fw_install_filters "$BR" "$SUBNET" "$GW" "$UP" "" eth
assert_failure "a parent whose catch-all would match the Supervisor network is refused" halow_fw_install_filters "$BR" "$SUBNET" "$GW" "$UP" "" hass
assert_eq "" "$(fw_log)" "...no iptables call for any of them"
assert_file_absent "$HALOW_STATE_DIR/owns/fw_filter" "...and no marker"

echo "-- catch-all failures and removal --"
fresh yes no
export HALOW_FAKE_FW_FAIL_MATCH="-A HALOW-PARENT6"
assert_failure "install fails when the IPv6 catch-all cannot be populated" halow_fw_install_filters "$BR" "$SUBNET" "$GW" "$UP" "" "$PAR"
unset HALOW_FAKE_FW_FAIL_MATCH
assert_eq "0" "$( (fw iptables -S; fw ip6tables -S) | grep -c -E -- 'HALOW-(IN|FWD-OUT|FWD-IN|PARENT)6?$')" "...everything installed so far was removed"
fresh yes no
halow_fw_install_filters "$BR" "$SUBNET" "$GW" "$UP" "" "$PAR" >/dev/null 2>&1
fw iptables -I FORWARD 1 -i "$PAR+" -j HALOW-PARENT
assert_success "remove_filters removes the catch-all in every hook location" halow_fw_remove_filters
assert_eq "0" "$( (fw iptables -S; fw ip6tables -S) | grep -c -- 'HALOW-PARENT')" "...no catch-all chain or jump remains"

# ---------------------------------------------------------------------------------------
echo "-- the ownership marker is written before the first change --"
fresh yes no
cat > "$HALOW_TEST_TMP/fakebin/iptables-guarded" <<EOF
#!/bin/sh
echo "\$*" >> "$HALOW_TEST_TMP/guarded.calls"
case " \$* " in
    *" -N "*|*" -A "*|*" -I "*)
        case " \$* " in
            *" -t nat "*) k=fw_nat ;;
            *) k=fw_filter ;;
        esac
        [ -e "$HALOW_STATE_DIR/owns/\$k" ] || echo "MUTATION-WITHOUT-MARKER \$k \$*" >> "$HALOW_FAKE_FW_DIR/log" ;;
esac
exec "$HALOW_TEST_TMP/fakebin/\${0##*/guarded-}" "\$@"
EOF
cp "$HALOW_TEST_TMP/fakebin/iptables-guarded" "$HALOW_TEST_TMP/fakebin/guarded-iptables"
cp "$HALOW_TEST_TMP/fakebin/iptables-guarded" "$HALOW_TEST_TMP/fakebin/guarded-ip6tables"
chmod +x "$HALOW_TEST_TMP/fakebin/guarded-iptables" "$HALOW_TEST_TMP/fakebin/guarded-ip6tables"
HALOW_IPTABLES="$HALOW_TEST_TMP/fakebin/guarded-iptables" HALOW_IP6TABLES="$HALOW_TEST_TMP/fakebin/guarded-ip6tables" \
    halow_fw_install_filters "$BR" "$SUBNET" "$GW" "$UP" "" "$PAR" >/dev/null 2>&1
HALOW_IPTABLES="$HALOW_TEST_TMP/fakebin/guarded-iptables" halow_fw_install_nat "$BR" "$SUBNET" "$UP" >/dev/null 2>&1
assert_success "the filter and NAT chains were installed through the guarded wrapper" fw_chain_exists iptables nat HALOW-NAT
assert_success "the wrapper saw the state-changing calls" test "$(grep -c -E -- ' -(N|A|I) ' "$HALOW_TEST_TMP/guarded.calls")" -gt 10
assert_eq "0" "$(fw_log_count 'MUTATION-WITHOUT-MARKER')" "no chain was created or filled, and no jump inserted, before its marker existed"
fresh yes no
halow_own_mark() { if [ "$1" = "fw_filter" ]; then return 1; fi; command -v true >/dev/null; }
assert_failure "install_filters fails when its marker cannot be written" halow_fw_install_filters "$BR" "$SUBNET" "$GW" "$UP" "" "$PAR"
assert_eq "0" "$(grep -c -E -- ' -(N|A|I|D|F|X) ' "$HALOW_FAKE_FW_DIR/log")" "...and changes nothing at all on the host"
unset -f halow_own_mark
. "$HALOW_LIB_DIR/ownership.sh"
halow_fw_install_filters "$BR" "$SUBNET" "$GW" "$UP" "" >/dev/null 2>&1
fw_log_reset
halow_own_mark() { if [ "$1" = "fw_nat" ]; then return 1; fi; local key="$1" content="${2:-}" dir="${HALOW_STATE_DIR:?}/owns"; mkdir -p "$dir"; printf '%s' "$content" > "$dir/$key"; }
assert_failure "install_nat fails when its marker cannot be written" halow_fw_install_nat "$BR" "$SUBNET" "$UP"
assert_eq "0" "$(grep -c -E -- ' -t nat -(N|A|I|D|F|X) ' "$HALOW_FAKE_FW_DIR/log")" "...and the nat table is not touched"
unset -f halow_own_mark
. "$HALOW_LIB_DIR/ownership.sh"

# ---------------------------------------------------------------------------------------
echo "-- re-assertion failures are reported (the caller fails closed) --"
fresh yes no
halow_fw_install_filters "$BR" "$SUBNET" "$GW" "$UP" "" "$PAR" >/dev/null 2>&1
fw iptables -D INPUT -i "$PAR+" -j HALOW-PARENT
assert_success "a lost catch-all jump is restored" halow_fw_reassert
assert_eq "-i $PAR+ -j HALOW-PARENT" "$(fw_rules iptables filter INPUT | sed -n 2p)" "...at INPUT position 2"
fw iptables -D INPUT -i "$BR" -j HALOW-IN
export HALOW_FAKE_FW_FAIL_MATCH="-I INPUT"
assert_exit 1 "a jump that cannot be restored returns 1" halow_fw_reassert
unset HALOW_FAKE_FW_FAIL_MATCH
assert_success "...and the next re-assertion restores it" halow_fw_reassert
export HALOW_FAKE_FW_FAIL_MATCH="iptables -w 5 -t filter -S"
assert_exit 1 "an unreadable table returns 1" halow_fw_reassert
unset HALOW_FAKE_FW_FAIL_MATCH
fw ip6tables -D INPUT -i "$PAR+" -j HALOW-PARENT6
fw ip6tables -D FORWARD -i "$PAR+" -j HALOW-PARENT6
fw ip6tables -F HALOW-PARENT6
fw ip6tables -X HALOW-PARENT6
assert_failure "the IPv6 chains no longer count as governing IPv6" halow_fw_ipv6_governed
assert_exit 1 "a recorded catch-all chain that disappeared returns 1" halow_fw_reassert
assert_eq "0" "$(fw ip6tables -S | grep -c -- '-j HALOW-PARENT6')" "...and no jump to the missing chain is created"
halow_fw_remove_filters >/dev/null 2>&1
fw iptables -t nat -N HALOW-NAT >/dev/null 2>&1 || true
halow_own_mark fw_nat x
fw iptables -t nat -X HALOW-NAT
assert_exit 1 "a recorded NAT chain that disappeared returns 1" halow_fw_reassert
halow_own_clear fw_nat

echo "-- IPv6 governance check --"
fresh no no
assert_failure "nothing installed: IPv6 is not governed" halow_fw_ipv6_governed
halow_fw_install_filters "$BR" "$SUBNET" "$GW" "$UP" "" >/dev/null 2>&1
assert_success "installed without a parent: governed" halow_fw_ipv6_governed
fw ip6tables -I FORWARD 1 -i docker0 -j ACCEPT
assert_failure "a jump moved from its position: not governed" halow_fw_ipv6_governed
halow_fw_reassert >/dev/null 2>&1
assert_success "after re-assertion: governed again" halow_fw_ipv6_governed
fw ip6tables -I HALOW-IN6 1 -j ACCEPT
fw ip6tables -D HALOW-IN6 2
assert_failure "a chain that no longer ends in its drop: not governed" halow_fw_ipv6_governed

# ---------------------------------------------------------------------------------------
echo "-- a held xtables lock cannot hang the caller --"
# run_bounded <limit_s> <cmd…> — runs <cmd> in the background; sets _rb_rc to its exit
# status, or to 124 when it was still running after <limit_s> seconds (then killed).
run_bounded() {
    local limit="$1" pid t=0
    shift
    rm -f -- "$HALOW_TEST_TMP/rb.rc"
    ( "$@" >/dev/null 2>&1; echo $? > "$HALOW_TEST_TMP/rb.rc" ) &
    pid=$!
    while [ ! -s "$HALOW_TEST_TMP/rb.rc" ] && [ "$t" -lt $((limit * 10)) ]; do
        command sleep 0.1; t=$((t + 1))
    done
    if [ -s "$HALOW_TEST_TMP/rb.rc" ]; then
        _rb_rc="$(cat "$HALOW_TEST_TMP/rb.rc")"
    else
        _rb_rc=124
        pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null
    fi
    wait "$pid" 2>/dev/null
    return 0
}
fresh yes no
halow_fw_install_filters "$BR" "$SUBNET" "$GW" "$UP" "" "$PAR" >/dev/null 2>&1
fw_log_reset
export HALOW_FAKE_FW_LOCK_HELD=1 HALOW_FAKE_FW_HANG_S=30
run_bounded 10 halow_fw_reassert
assert_eq "1" "$_rb_rc" "re-assertion with the lock held elsewhere returns 1 within the bound (not a hang)"
assert_eq "0" "$(fw_log_count 'LOCK-HANG')" "...every call used a bounded lock wait"
assert_success "...and the lock was really contended" test "$(fw_log_count 'LOCK-TIMEOUT')" -ge 1
run_bounded 10 halow_fw_remove_filters
assert_eq "1" "$_rb_rc" "removal with the lock held returns 1 (unconfirmed) within the bound"
assert_file_exists "$HALOW_STATE_DIR/owns/fw_filter" "...and keeps its marker"
fresh yes no
export HALOW_FAKE_FW_LOCK_HELD=1 HALOW_FAKE_FW_HANG_S=30
run_bounded 10 halow_fw_install_filters "$BR" "$SUBNET" "$GW" "$UP" "" "$PAR"
assert_eq "1" "$_rb_rc" "install with the lock held fails within the bound"
unset HALOW_FAKE_FW_LOCK_HELD HALOW_FAKE_FW_HANG_S

halow_test_teardown
echo "test_firewall: $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed"
exit $([ "$HALOW_TEST_FAILURES" -eq 0 ] && echo 0 || echo 1)
