#!/usr/bin/env bash
# Asserts the selective traffic policy as behaviour: the rules firewall.sh installs (in the
# fake iptables state, next to a small Docker-like rule set whose FORWARD and INPUT
# policies are ACCEPT, the worst case) are walked by tests/fakes/fw_eval.sh for synthetic
# packets of every traffic class.
#
# The evaluator is a MODEL of the rule semantics, not proof of kernel behaviour: these
# results show what the installed rules decide if the kernel matches as modelled; the
# real traffic classes await live validation on the target device.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh
halow_test_setup
. ./fakes/fw_helpers.sh

echo "== test_firewall_policy =="

BR=halow-br0
GW=192.168.90.1
CL=192.168.90.50      # a HaLow client
HOSTLAN=192.168.1.10  # the host's LAN address
LANDEV=192.168.1.20   # a device on the customer LAN
CONT=172.30.33.5      # an add-on container on the Supervisor network

policy_suite() { # policy_suite <label>
    local L="$1" I=iptables
    echo "-- $L: HaLow client to the host --"
    assert_verdict ACCEPT "$L: DHCP discover (broadcast) accepted" $I INPUT in=$BR src=0.0.0.0 dst=255.255.255.255 proto=udp dport=67
    assert_verdict ACCEPT "$L: DHCP unicast renewal to the gateway accepted" $I INPUT in=$BR src=$CL dst=$GW proto=udp dport=67
    assert_verdict DROP "$L: DHCP to another host address dropped" $I INPUT in=$BR src=$CL dst=$HOSTLAN proto=udp dport=67
    assert_verdict ACCEPT "$L: DNS/udp to the gateway accepted" $I INPUT in=$BR src=$CL dst=$GW proto=udp dport=53
    assert_verdict ACCEPT "$L: DNS/tcp to the gateway accepted" $I INPUT in=$BR src=$CL dst=$GW proto=tcp dport=53
    assert_verdict DROP "$L: DNS to the host's LAN address dropped" $I INPUT in=$BR src=$CL dst=$HOSTLAN proto=udp dport=53
    assert_verdict DROP "$L: DNS to the Docker gateway address dropped" $I INPUT in=$BR src=$CL dst=172.30.32.1 proto=udp dport=53
    assert_verdict ACCEPT "$L: ICMP echo to the gateway accepted" $I INPUT in=$BR src=$CL dst=$GW proto=icmp icmp=8
    assert_verdict DROP "$L: ICMP echo to the host's LAN address dropped" $I INPUT in=$BR src=$CL dst=$HOSTLAN proto=icmp icmp=8
    assert_verdict ACCEPT "$L: ICMP error related to a session accepted" $I INPUT in=$BR src=$CL dst=$GW proto=icmp icmp=3 ctstate=RELATED
    assert_verdict DROP "$L: a non-ICMP RELATED packet dropped (no helpers)" $I INPUT in=$BR src=$CL dst=$GW proto=tcp dport=21 ctstate=RELATED
    assert_verdict ACCEPT "$L: reply to a connection Home Assistant opened accepted" $I INPUT in=$BR src=$CL dst=$GW proto=tcp sport=80 dport=40000 ctstate=ESTABLISHED
    assert_verdict DROP "$L: Home Assistant (8123) not reachable unless allow-listed" $I INPUT in=$BR src=$CL dst=$GW proto=tcp dport=8123
    assert_verdict ACCEPT "$L: allow-listed host port (tcp/1883) on the gateway accepted" $I INPUT in=$BR src=$CL dst=$GW proto=tcp dport=1883
    assert_verdict DROP "$L: allow-listed port with the other protocol dropped" $I INPUT in=$BR src=$CL dst=$GW proto=udp dport=1883
    assert_verdict DROP "$L: allow-listed port on another host address dropped" $I INPUT in=$BR src=$CL dst=$HOSTLAN proto=tcp dport=1883
    assert_verdict DROP "$L: SSH dropped" $I INPUT in=$BR src=$CL dst=$GW proto=tcp dport=22
    assert_verdict DROP "$L: an Ingress-range port dropped" $I INPUT in=$BR src=$CL dst=$GW proto=tcp dport=63000
    assert_verdict DROP "$L: mDNS multicast dropped" $I INPUT in=$BR src=$CL dst=224.0.0.251 proto=udp dport=5353
    assert_verdict DROP "$L: IGMP dropped" $I INPUT in=$BR src=$CL dst=224.0.0.22 proto=igmp
    assert_verdict ACCEPT "$L: traffic not from the bridge is left to the host (loopback)" $I INPUT in=lo src=127.0.0.1 dst=127.0.0.1 proto=tcp dport=8123
    assert_verdict ACCEPT "$L: LAN traffic to the host is not governed by the add-on" $I INPUT in=eth0 src=$LANDEV dst=$HOSTLAN proto=tcp dport=8123

    echo "-- $L: HaLow client forwarded --"
    assert_verdict ACCEPT "$L: client to a LAN device through the uplink accepted" $I FORWARD in=$BR out=eth0 src=$CL dst=$LANDEV proto=tcp dport=80
    assert_verdict ACCEPT "$L: client to the Internet through the uplink accepted" $I FORWARD in=$BR out=eth0 src=$CL dst=8.8.8.8 proto=udp dport=53
    assert_verdict DROP "$L: spoofed source towards the uplink dropped" $I FORWARD in=$BR out=eth0 src=10.9.9.9 dst=$LANDEV proto=tcp dport=80
    assert_verdict DROP "$L: client to the Supervisor network dropped" $I FORWARD in=$BR out=hassio src=$CL dst=$CONT proto=tcp dport=1883
    assert_verdict DROP "$L: client to docker0 dropped" $I FORWARD in=$BR out=docker0 src=$CL dst=172.17.0.2 proto=tcp dport=80
    assert_verdict DROP "$L: client to a VPN interface dropped" $I FORWARD in=$BR out=wg0 src=$CL dst=10.8.0.1 proto=tcp dport=80
    assert_verdict ACCEPT "$L: allow-listed DNAT'd published port accepted" $I FORWARD in=$BR out=hassio src=$CL dst=$CONT proto=tcp dport=1883 ctstate=NEW,DNAT origdst=$GW origdport=1883
    assert_verdict DROP "$L: DNAT'd published port not on the allow-list dropped" $I FORWARD in=$BR out=hassio src=$CL dst=$CONT proto=tcp dport=8080 ctstate=NEW,DNAT origdst=$GW origdport=8080
    assert_verdict DROP "$L: DNAT'd port through another original address dropped" $I FORWARD in=$BR out=hassio src=$CL dst=$CONT proto=tcp dport=1883 ctstate=NEW,DNAT origdst=$HOSTLAN origdport=1883
    assert_verdict DROP "$L: direct, unpublished container port dropped even with an allow-listed number" $I FORWARD in=$BR out=hassio src=$CL dst=$CONT proto=tcp dport=1883
    assert_verdict DROP "$L: client to client across the bridge (bridge netfilter on) dropped" $I FORWARD in=$BR out=$BR src=$CL dst=192.168.90.51 proto=tcp dport=80
    assert_verdict ACCEPT "$L: reply to an add-on's session leaving the bridge accepted" $I FORWARD in=$BR out=hassio src=$CL dst=$CONT proto=tcp sport=80 ctstate=ESTABLISHED

    echo "-- $L: towards HaLow devices --"
    assert_verdict DROP "$L: new connection from a LAN device dropped" $I FORWARD in=eth0 out=$BR src=$LANDEV dst=$CL proto=tcp dport=80
    assert_verdict ACCEPT "$L: LAN reply to a HaLow-originated session accepted" $I FORWARD in=eth0 out=$BR src=$LANDEV dst=$CL proto=tcp sport=80 ctstate=ESTABLISHED
    assert_verdict ACCEPT "$L: ICMP error related to a HaLow session accepted" $I FORWARD in=eth0 out=$BR src=$LANDEV dst=$CL proto=icmp icmp=3 ctstate=RELATED
    assert_verdict ACCEPT "$L: new connection from the Supervisor network accepted" $I FORWARD in=hassio out=$BR src=$CONT dst=$CL proto=tcp dport=80
    assert_verdict DROP "$L: new connection from docker0 dropped" $I FORWARD in=docker0 out=$BR src=172.17.0.2 dst=$CL proto=tcp dport=80
    assert_verdict DROP "$L: new connection from a user-defined Docker network dropped" $I FORWARD in=br-1a2b3c out=$BR src=172.18.0.2 dst=$CL proto=tcp dport=80
    assert_verdict DROP "$L: new connection from a VPN interface dropped" $I FORWARD in=wg0 out=$BR src=10.8.0.2 dst=$CL proto=tcp dport=80
    assert_verdict ACCEPT "$L: unrelated container traffic still decided by Docker's rules" $I FORWARD in=hassio out=eth0 src=$CONT dst=8.8.8.8 proto=udp dport=53

    echo "-- $L: IPv6 --"
    assert_verdict DROP "$L: IPv6 from a HaLow client to the host dropped" ip6tables INPUT in=$BR proto=udp dport=53
    assert_verdict DROP "$L: IPv6 neighbour discovery from the bridge dropped" ip6tables INPUT in=$BR proto=icmpv6
    assert_verdict DROP "$L: IPv6 forwarded from a HaLow client dropped" ip6tables FORWARD in=$BR out=eth0 proto=tcp dport=80
    assert_verdict DROP "$L: IPv6 forwarded to HaLow from the Supervisor network dropped" ip6tables FORWARD in=hassio out=$BR proto=tcp dport=80
    assert_verdict DROP "$L: IPv6 established towards HaLow dropped" ip6tables FORWARD in=eth0 out=$BR proto=tcp ctstate=ESTABLISHED
    assert_verdict ACCEPT "$L: IPv6 not touching the bridge left to the host" ip6tables INPUT in=eth0 proto=tcp dport=8123

    echo "-- $L: the radio's own interfaces outside the bridge --"
    assert_verdict DROP "$L: the parent outside the bridge cannot reach SSH on the host" $I INPUT in=wlu1 src=$CL dst=$GW proto=tcp dport=22
    assert_verdict DROP "$L: the parent outside the bridge cannot even use DHCP" $I INPUT in=wlu1 src=0.0.0.0 dst=255.255.255.255 proto=udp dport=67
    assert_verdict DROP "$L: an unbridged per-station interface cannot reach the host" $I INPUT in=wlu1.sta7 src=$CL dst=$HOSTLAN proto=tcp dport=8123
    assert_verdict DROP "$L: an unbridged per-station interface is not forwarded to the LAN" $I FORWARD in=wlu1.sta7 out=eth0 src=$CL dst=$LANDEV proto=tcp dport=80
    assert_verdict DROP "$L: an unbridged per-station interface is not forwarded to the Supervisor network" $I FORWARD in=wlu1.sta7 out=hassio src=$CL dst=$CONT proto=tcp dport=1883 ctstate=ESTABLISHED
    assert_verdict DROP "$L: IPv6 from an unbridged per-station interface to the host dropped" ip6tables INPUT in=wlu1.sta7 proto=udp dport=53
    assert_verdict DROP "$L: IPv6 forwarded from the unbridged parent dropped" ip6tables FORWARD in=wlu1 out=eth0 proto=tcp dport=80
    assert_verdict ACCEPT "$L: the same client through the bridge still gets DHCP" $I INPUT in=$BR src=0.0.0.0 dst=255.255.255.255 proto=udp dport=67
    assert_verdict ACCEPT "$L: an interface that only resembles the parent is not caught" $I INPUT in=wlx1 src=$LANDEV dst=$HOSTLAN proto=tcp dport=8123
}

echo "-- before install: the worst case the add-on must govern --"
fw_fake_setup
fw_docker_setup iptables yes
fw_docker_setup ip6tables yes
assert_verdict ACCEPT "without the chains, a client reaches SSH on the host (shows the test can fail)" iptables INPUT in=$BR src=$CL dst=$GW proto=tcp dport=22
assert_verdict ACCEPT "without the chains, docker0 reaches HaLow devices" iptables FORWARD in=docker0 out=$BR src=172.17.0.2 dst=$CL proto=tcp dport=80
assert_verdict ACCEPT "without the catch-all, an unbridged per-station interface reaches SSH on the host" iptables INPUT in=wlu1.sta7 src=$CL dst=$GW proto=tcp dport=22

halow_fw_install_filters "$BR" 192.168.90.1/24 "$GW" eth0 "tcp/1883" wlu1 >/dev/null 2>&1
policy_suite "DOCKER-USER hook"

fw_fake_setup
fw_docker_setup iptables no
fw_docker_setup ip6tables no
halow_fw_install_filters "$BR" 192.168.90.1/24 "$GW" eth0 "tcp/1883" wlu1 >/dev/null 2>&1
policy_suite "FORWARD fallback"

echo "-- the window after a Docker restart, and re-assertion --"
fw iptables -I FORWARD 1 -i docker0 -j ACCEPT
assert_verdict ACCEPT "a Docker rule inserted above the jumps opens docker0 to HaLow (the window)" iptables FORWARD in=docker0 out=$BR src=172.17.0.2 dst=$CL proto=tcp dport=80
halow_fw_reassert >/dev/null 2>&1
assert_verdict DROP "after re-assertion docker0 to HaLow is dropped again" iptables FORWARD in=docker0 out=$BR src=172.17.0.2 dst=$CL proto=tcp dport=80
assert_verdict ACCEPT "after re-assertion the Supervisor network still reaches HaLow" iptables FORWARD in=hassio out=$BR src=$CONT dst=$CL proto=tcp dport=80

echo "-- evaluator honesty --"
fw iptables -N X-UNKNOWN
fw iptables -A X-UNKNOWN -m set --match-set foo src -j ACCEPT
fw iptables -I INPUT 1 -j X-UNKNOWN
HALOW_TEST_COUNT=$((HALOW_TEST_COUNT + 1))
if fw_verdict iptables INPUT in=$BR src=$CL dst=$GW proto=tcp dport=22 >/dev/null 2>&1; then
    echo "  FAIL: the evaluator silently accepted an unmodelled rule element"; HALOW_TEST_FAILURES=$((HALOW_TEST_FAILURES + 1))
else
    echo "  ok: the evaluator reports an unmodelled rule element as an error"
fi

halow_test_teardown
echo "test_firewall_policy: $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed"
exit $([ "$HALOW_TEST_FAILURES" -eq 0 ] && echo 0 || echo 1)
