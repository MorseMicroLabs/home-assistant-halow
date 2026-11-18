#!/usr/bin/env bash
# Tests the station lifecycle in the core (rootfs/usr/lib/halow/stations.sh) against the
# test-double backend (tests/doubles/backend_double.sh), which records every contract call
# and flags call-sequence violations. Each scenario proves which operations the core
# issued and in which order, for any number of stations of both kinds (ordinary stations
# on the parent, four-address stations on their own interfaces), arriving and leaving in
# any order, plus the snapshot view (station rows, downstream devices and their addresses, connection times), bounded log rotation and the strict error semantics.
# The real bridge backend is driven by the same core in test_backend_bridge.sh.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
_TESTS_DIR="$PWD"
. ./test_helpers.sh
. ./doubles/backend_double.sh

halow_test_setup
export HALOW_DBL_LOG="$HALOW_TEST_TMP/double.calls"
LOG="$HALOW_TEST_TMP/hostapd.log"
BR=halow-br0
STA1="aa:bb:cc:00:00:01"; STA2="aa:bb:cc:00:00:02"; STA3="aa:bb:cc:00:00:03"; STA4="aa:bb:cc:00:00:04"

_clock=1000
halow_st_now() { printf '%s' "$_clock"; }
sleep() { return 0; }
halow_kernel_iface_exists() { [ "$1" != "${_missing_iface:-}" ]; }

run_pl() { if halow_st_process_log; then _pl_rc=0; else _pl_rc=$?; fi; }
calls() { grep -v '^health' "$HALOW_DBL_LOG" || true; }
violations() { grep -c VIOLATION "$HALOW_DBL_LOG" || true; }

# new_scenario: fresh state, double registered and attached to the bridge at start.
new_scenario() {
    : > "$LOG"; : > "$HALOW_DBL_LOG"; rm -f "$HALOW_DBL_LOG".attached "$HALOW_DBL_LOG".live "$HALOW_DBL_LOG".ports
    _missing_iface=""; _clock=1000
    unset HALOW_DBL_HEALTH_RC HALOW_DBL_ADD_RC HALOW_DBL_REMOVE_RC HALOW_DBL_MAX_STATIONS HALOW_DBL_ATTACH_RC
    HALOW_ST_ORDINARY_WAIT_S=3
    HALOW_ST_RELOG_CMD=()
    HALOW_BACKEND_NAME=""; halow_backend_register double
    halow_st_reset "$LOG" "wlu1" "$BR"
    if [ "${1:-attach}" = "attach" ]; then halow_st_attach "$BR" 2>/dev/null; : > "$HALOW_DBL_LOG"; fi
}

echo "== test_station_lifecycle: event parsing =="
new_scenario
halow_st_parse_event "wlu1: AP-STA-CONNECTED AA:BB:CC:00:00:01"
assert_eq "station_added|aa:bb:cc:00:00:01" "$HALOW_ST_EV_KIND|$HALOW_ST_EV_MAC" "a connect line, with an interface prefix and upper-case MAC, is parsed and the MAC normalised"
halow_st_parse_event "AP-STA-CONNECTED aa:bb:cc:00:00:02 aid=1"
assert_eq "aa:bb:cc:00:00:02" "$HALOW_ST_EV_MAC" "trailing fields after the MAC are ignored"
halow_st_parse_event "AP-STA-DISCONNECTED aa:bb:cc:00:00:01"
assert_eq "station_removed|aa:bb:cc:00:00:01" "$HALOW_ST_EV_KIND|$HALOW_ST_EV_MAC" "a disconnect line is parsed"
halow_st_parse_event "WDS-STA-INTERFACE-ADDED ifname=wlu1.sta1"
assert_eq "iface_added||wlu1.sta1" "$HALOW_ST_EV_KIND|$HALOW_ST_EV_MAC|$HALOW_ST_EV_IFACE" "an interface-added line without a station address is parsed"
halow_st_parse_event "wlu1: WDS-STA-INTERFACE-ADDED ifname=wlu1.sta2 sta_addr=AA:BB:CC:00:00:02"
assert_eq "iface_added|aa:bb:cc:00:00:02|wlu1.sta2" "$HALOW_ST_EV_KIND|$HALOW_ST_EV_MAC|$HALOW_ST_EV_IFACE" "sta_addr=<mac> (the form hostapd_s1g prints) is read"
halow_st_parse_event "WDS-STA-INTERFACE-ADDED ifname=wlu1.sta2 sta=AA:BB:CC:00:00:02"
assert_eq "aa:bb:cc:00:00:02" "$HALOW_ST_EV_MAC" "sta=<mac> is accepted too"
halow_st_parse_event "WDS-STA-INTERFACE-REMOVED ifname=wlu1.sta2"
assert_eq "iface_removed|wlu1.sta2" "$HALOW_ST_EV_KIND|$HALOW_ST_EV_IFACE" "an interface-removed line is parsed"
assert_failure "an unrelated hostapd line is not an event" halow_st_parse_event "EAPOL-4WAY-HS-COMPLETED aa:bb:cc:00:00:01"
assert_failure "a connect line with no MAC is rejected" halow_st_parse_event "AP-STA-CONNECTED"
assert_failure "an interface line with no name is rejected" halow_st_parse_event "WDS-STA-INTERFACE-ADDED"
assert_failure "an interface name that fails validation is rejected (never passed to a backend)" halow_st_parse_event 'WDS-STA-INTERFACE-ADDED ifname=wlu1.sta1;rm'

echo "== test_station_lifecycle: the bridge is attached at start, with zero stations =="
new_scenario noattach
_saved_brname="$HALOW_BRIDGE_NAME"; HALOW_BRIDGE_NAME=""
halow_st_reset "$LOG" "wlu1"
echo "AP-STA-CONNECTED $STA1" >> "$LOG"
run_pl; assert_eq "1" "$_pl_rc" "with no bridge known, events are not processed"
assert_eq "" "$(calls)" "...and nothing reaches the backend"
HALOW_BRIDGE_NAME="$_saved_brname"
halow_st_reset "$LOG" "wlu1"
assert_eq "$BR" "$HALOW_ST_BRIDGE" "the bridge defaults to HALOW_BRIDGE_NAME"
assert_success "attach" halow_st_attach "$BR"
assert_eq "attach bridge $BR" "$(calls)" "the backend is attached once, to the bridge, before any station"
assert_eq "$BR" "$HALOW_ST_ATTACHMENT" "the attachment is the bridge"
assert_failure "a second attach is refused by the core" halow_st_attach "$BR"
assert_eq "1" "$(grep -c '^attach' "$HALOW_DBL_LOG")" "...without calling the backend again"
_clock=1003
assert_success "the station associated before the attach is processed afterwards" halow_st_process_log
assert_eq "attach bridge $BR" "$(calls)" "...its wait for an interface starts when its line is read"
_clock=1006
halow_st_process_log
assert_eq "station_added wlu1 $STA1" "$(tail -n1 "$HALOW_DBL_LOG")" "...and it is then served as an ordinary station"
new_scenario noattach
halow_backend_call attach bridge "$BR" >/dev/null 2>&1
halow_st_reset "$LOG" "wlu1"
echo "WDS-STA-INTERFACE-ADDED ifname=wlu1.sta1 sta_addr=$STA1" >> "$LOG"; echo "AP-STA-CONNECTED $STA1" >> "$LOG"
assert_success "a caller that attached the backend itself can process events directly" halow_st_process_log
assert_eq "$BR" "$HALOW_ST_ATTACHMENT" "...the bridge is taken as the attachment"
assert_eq "attach bridge $BR
station_added wlu1.sta1 $STA1" "$(calls)" "...with no second attach"
new_scenario noattach
export HALOW_DBL_ATTACH_RC=1
assert_failure "a backend that cannot attach makes the start-up attach fail" halow_st_attach "$BR"
assert_eq "" "$HALOW_ST_ATTACHMENT" "...and no attachment is recorded"
unset HALOW_DBL_ATTACH_RC
new_scenario noattach
export HALOW_DBL_ATTACH_RC=10
assert_failure "a limit (10) answer to the one attach is a failure too" halow_st_attach "$BR"
unset HALOW_DBL_ATTACH_RC

echo "== test_station_lifecycle: four-address stations, interface announced before and after =="
new_scenario
cat >> "$LOG" <<EOF
WDS-STA-INTERFACE-ADDED ifname=wlu1.sta1
AP-STA-CONNECTED $STA1
AP-STA-CONNECTED $STA2
WDS-STA-INTERFACE-ADDED ifname=wlu1.sta2
EOF
assert_success "the events are processed" halow_st_process_log
assert_eq "station_added wlu1.sta1 $STA1
station_added wlu1.sta2 $STA2" "$(calls)" "each station is reported on its own interface, whichever came first"
assert_eq "wds|wds" "${HALOW_ST_KIND[$STA1]}|${HALOW_ST_KIND[$STA2]}" "both are four-address stations"
assert_eq "2" "$(halow_st_associated_count)" "two stations are associated"
cat >> "$LOG" <<EOF
AP-STA-DISCONNECTED $STA1
AP-STA-DISCONNECTED $STA2
EOF
halow_st_process_log
assert_eq "station_removed wlu1.sta1 $STA1
station_removed wlu1.sta2 $STA2" "$(calls | tail -n 2)" "each departure frees the port that station used"
assert_eq "0" "$(halow_st_associated_count)" "none is associated afterwards"
assert_eq "offline" "${HALOW_ST_STATE[$STA1]}" "a departed station is recorded offline"
assert_eq "0" "$(violations)" "the double saw no call-sequence violation"

echo "== test_station_lifecycle: pairing follows the MAC, not the arrival order =="
new_scenario
cat >> "$LOG" <<EOF
AP-STA-CONNECTED $STA1
AP-STA-CONNECTED $STA2
WDS-STA-INTERFACE-ADDED ifname=wlu1.sta2 sta_addr=$STA2
WDS-STA-INTERFACE-ADDED ifname=wlu1.sta1 sta_addr=$STA1
EOF
halow_st_process_log
assert_eq "wlu1.sta1|wlu1.sta2" "${HALOW_ST_IFACE[$STA1]}|${HALOW_ST_IFACE[$STA2]}" "each station is bound to ITS interface"
new_scenario
echo "WDS-STA-INTERFACE-ADDED ifname=wlu1.sta1 sta_addr=$STA1" >> "$LOG"
halow_st_process_log
assert_eq "" "$(calls)" "nothing is reported for a station that has not associated yet"
echo "AP-STA-CONNECTED $STA1" >> "$LOG"
halow_st_process_log
assert_eq "station_added wlu1.sta1 $STA1" "$(calls)" "the station is reported exactly once, when it associates, on its announced interface"

echo "== test_station_lifecycle: ordinary stations =="
new_scenario
echo "AP-STA-CONNECTED $STA1" >> "$LOG"
halow_st_process_log
assert_eq "" "$(calls)" "a station with no interface yet is held, not guessed at"
assert_eq "$STA1" "$HALOW_ST_AWAITING_MACS" "...and waits"
_clock=1002
halow_st_process_log
assert_eq "" "$(calls)" "...still within the wait (2 s of 3)"
_clock=1003
halow_st_process_log
assert_eq "station_added wlu1 $STA1" "$(calls)" "after HALOW_ST_ORDINARY_WAIT_S it is an ordinary station on the parent"
assert_eq "ordinary|wlu1|1" "${HALOW_ST_KIND[$STA1]}|${HALOW_ST_IFACE[$STA1]}|${HALOW_ST_SERVED[$STA1]}" "...kind ordinary, port the parent, served"
assert_eq "" "$HALOW_ST_AWAITING_MACS" "...and no longer waiting"
_clock=1010; halow_st_process_log
assert_eq "1" "$(calls | grep -c .)" "it is not reported again on later passes"
echo "AP-STA-DISCONNECTED $STA1" >> "$LOG"
halow_st_process_log
assert_eq "station_removed wlu1 $STA1" "$(calls | tail -n1)" "its departure frees the parent port it used"
new_scenario
HALOW_ST_ORDINARY_WAIT_S=10
echo "AP-STA-CONNECTED $STA1" >> "$LOG"; halow_st_process_log
_clock=1009; halow_st_process_log
assert_eq "" "$(calls)" "the wait is configurable (HALOW_ST_ORDINARY_WAIT_S=10: nothing at 9 s)"
_clock=1010; halow_st_process_log
assert_eq "station_added wlu1 $STA1" "$(calls)" "...and served at 10 s"
new_scenario
echo "AP-STA-CONNECTED $STA1" >> "$LOG"; halow_st_process_log
echo "AP-STA-DISCONNECTED $STA1" >> "$LOG"; _clock=1005; halow_st_process_log
assert_eq "" "$(calls)" "a station that leaves within the wait is never reported (nothing to free)"
assert_eq "" "$HALOW_ST_AWAITING_MACS" "...and is forgotten"

echo "== test_station_lifecycle: an ordinary station later rebound to its own interface =="
new_scenario
echo "AP-STA-CONNECTED $STA1" >> "$LOG"; halow_st_process_log
_clock=1003; halow_st_process_log
echo "WDS-STA-INTERFACE-ADDED ifname=wlu1.sta1 sta_addr=$STA1" >> "$LOG"
_clock=1010; halow_st_process_log
assert_eq "station_added wlu1 $STA1
station_added wlu1.sta1 $STA1" "$(calls)" "one further station_added on the new port, no removal of the parent"
assert_eq "wds|wlu1.sta1" "${HALOW_ST_KIND[$STA1]}|${HALOW_ST_IFACE[$STA1]}" "...it is now a four-address station on its interface"
echo "WDS-STA-INTERFACE-ADDED ifname=wlu1.sta1 sta_addr=$STA1" >> "$LOG"
halow_st_process_log
assert_eq "2" "$(calls | grep -c '^station_added')" "a repeated announcement does not rebind again (exactly once)"
echo "AP-STA-DISCONNECTED $STA1" >> "$LOG"; halow_st_process_log
assert_eq "station_removed wlu1.sta1 $STA1" "$(calls | tail -n1)" "the departure frees the interface it was rebound to"
assert_eq "0" "$(violations)" "the double saw no call-sequence violation"

echo "== test_station_lifecycle: many stations of both kinds, any order, reassociation and port reuse =="
new_scenario
cat >> "$LOG" <<EOF
AP-STA-CONNECTED $STA4
WDS-STA-INTERFACE-ADDED ifname=wlu1.sta1 sta_addr=$STA1
AP-STA-CONNECTED $STA1
WDS-STA-INTERFACE-ADDED ifname=wlu1.sta2 sta_addr=$STA2
AP-STA-CONNECTED $STA2
AP-STA-DISCONNECTED $STA1
WDS-STA-INTERFACE-REMOVED ifname=wlu1.sta1
WDS-STA-INTERFACE-ADDED ifname=wlu1.sta1 sta_addr=$STA3
AP-STA-CONNECTED $STA3
EOF
assert_success "a mixed sequence is processed" halow_st_process_log
_clock=1004
halow_st_process_log   # the station with no interface has now waited long enough
cat >> "$LOG" <<EOF
AP-STA-DISCONNECTED $STA2
AP-STA-DISCONNECTED $STA3
AP-STA-CONNECTED $STA1
WDS-STA-INTERFACE-ADDED ifname=wlu1.sta3 sta_addr=$STA1
AP-STA-DISCONNECTED $STA4
EOF
assert_success "...and its continuation" halow_st_process_log
assert_eq "station_added wlu1.sta1 $STA1
station_added wlu1.sta2 $STA2
station_removed wlu1.sta1 $STA1
station_added wlu1.sta1 $STA3
station_added wlu1 $STA4
station_removed wlu1.sta2 $STA2
station_removed wlu1.sta1 $STA3
station_added wlu1.sta3 $STA1
station_removed wlu1 $STA4" "$(calls)" "every station arrives and leaves on its own port; a reused interface name serves the new station; the ordinary one waits, then uses the parent"
assert_eq "$BR" "$HALOW_ST_ATTACHMENT" "the attachment stays the bridge throughout"
assert_eq "1" "$(halow_st_associated_count)" "one station is associated at the end"
assert_eq "0" "$(violations)" "the double saw no call-sequence violation"
assert_eq "0" "$(grep -c '^attach' "$HALOW_DBL_LOG")" "and no station event ever attaches again"

echo "== test_station_lifecycle: an interface vanishing under a bound station =="
new_scenario
cat >> "$LOG" <<EOF
WDS-STA-INTERFACE-ADDED ifname=wlu1.sta2 sta_addr=$STA2
AP-STA-CONNECTED $STA2
WDS-STA-INTERFACE-REMOVED ifname=wlu1.sta2
EOF
halow_st_process_log
assert_eq "" "${HALOW_ST_IFACE[$STA2]}" "the binding to a removed interface is dropped"
assert_eq "station_removed wlu1.sta2 $STA2" "$(calls | tail -n 1)" "...the backend is told the port is gone"
assert_eq "$STA2" "$HALOW_ST_AWAITING_MACS" "...and the still-associated station waits for a new port"
echo "WDS-STA-INTERFACE-ADDED ifname=wlu1.sta2 sta_addr=$STA2" >> "$LOG"
halow_st_process_log
assert_eq "station_added wlu1.sta2 $STA2" "$(calls | tail -n 1)" "a new interface that reuses the name is paired again"
assert_eq "0" "$(violations)" "the double saw no call-sequence violation"
new_scenario
echo "WDS-STA-INTERFACE-ADDED ifname=wlu1.sta1" >> "$LOG"; halow_st_process_log
echo "WDS-STA-INTERFACE-REMOVED ifname=wlu1.sta1" >> "$LOG"; halow_st_process_log
assert_eq "" "$HALOW_ST_PENDING_IFACES" "an announced interface that disappears before any station used it is forgotten"

echo "== test_station_lifecycle: only a real <parent>.sta<N> interface is bound =="
for _bad in wlu1 other.sta1 wlu1.stax wlu1.sta; do
    new_scenario
    printf 'WDS-STA-INTERFACE-ADDED ifname=%s sta_addr=%s\nAP-STA-CONNECTED %s\n' "$_bad" "$STA1" "$STA1" >> "$LOG"
    run_pl; assert_eq "1" "$_pl_rc" "an announced name '$_bad' is refused"
    assert_eq "" "$(calls)" "...and the backend was not told about it"
done
new_scenario
_missing_iface="wlu1.sta1"
printf 'WDS-STA-INTERFACE-ADDED ifname=wlu1.sta1 sta_addr=%s\nAP-STA-CONNECTED %s\n' "$STA1" "$STA1" >> "$LOG"
run_pl; assert_eq "1" "$_pl_rc" "an announced name the kernel does not have is refused"
assert_eq "" "$(calls)" "...before any backend call"
assert_eq "0" "$HALOW_ST_FAULT" "...and that is not a backend fault"

echo "== test_station_lifecycle: the capacity limit (10) is not a failure =="
new_scenario
export HALOW_DBL_MAX_STATIONS=1
cat >> "$LOG" <<EOF
WDS-STA-INTERFACE-ADDED ifname=wlu1.sta1 sta_addr=$STA1
AP-STA-CONNECTED $STA1
WDS-STA-INTERFACE-ADDED ifname=wlu1.sta2 sta_addr=$STA2
AP-STA-CONNECTED $STA2
EOF
halow_report_healthy "up"
assert_success "a backend that declines a station is NOT a failure" halow_st_process_log
assert_eq "1|0" "${HALOW_ST_SERVED[$STA1]}|${HALOW_ST_SERVED[$STA2]}" "the first is served, the second recorded as not served"
assert_eq "2" "$(halow_st_associated_count)" "...but it is still tracked as associated"
assert_eq "0" "$HALOW_ST_FAULT" "...no fault is recorded"
halow_st_check_health
assert_success "...and the healthy marker stays" halow_is_healthy
echo "AP-STA-DISCONNECTED $STA1" >> "$LOG"; echo "AP-STA-CONNECTED $STA2" >> "$LOG"
halow_st_process_log
assert_eq "1" "${HALOW_ST_SERVED[$STA2]}" "after the first leaves, a repeated association of the second is served (the backend's answer, not a stale one)"
assert_eq "0" "$(violations)" "the double saw no call-sequence violation"
unset HALOW_DBL_MAX_STATIONS

echo "== test_station_lifecycle: incremental reading =="
new_scenario
echo "WDS-STA-INTERFACE-ADDED ifname=wlu1.sta1 sta_addr=$STA1" >> "$LOG"; echo "AP-STA-CONNECTED $STA1" >> "$LOG"
halow_st_process_log
_n1="$(calls | grep -c .)"
halow_st_process_log; halow_st_process_log
assert_eq "$_n1" "$(calls | grep -c .)" "re-reading an unchanged log reports nothing twice"
echo "AP-STA-DISCONNECTED $STA1" >> "$LOG"
halow_st_process_log
assert_eq "$((_n1 + 1))" "$(calls | grep -c .)" "only the newly appended line is processed"
printf 'WDS-STA-INTERFACE-ADDED ifname=wlu1.sta2 sta_addr=%s' "$STA2" >> "$LOG"
echo "" >> "$LOG"
printf 'AP-STA-CONNECTED %s' "$STA2" >> "$LOG"   # no trailing newline: an incomplete line
halow_st_process_log
assert_eq "" "${HALOW_ST_STATE[$STA2]:-}" "an incomplete last line is not processed until it is complete"
echo "" >> "$LOG"
halow_st_process_log
assert_eq "associated" "${HALOW_ST_STATE[$STA2]:-}" "...and is processed once its newline arrives"
new_scenario
rm -f "$LOG"
assert_success "a log file that does not exist yet is not an error" halow_st_process_log

echo "== test_station_lifecycle: connection times =="
new_scenario
echo "AP-STA-CONNECTED $STA2" >> "$LOG"; halow_st_process_log
assert_eq "1000|1000" "${HALOW_ST_CONNECTED_AT[$STA2]}|${HALOW_ST_CHANGED_AT[$STA2]}" "a new connection sets both the connected-since and the changed-at time"
_clock=1200
echo "AP-STA-CONNECTED $STA2" >> "$LOG"; halow_st_process_log
assert_eq "1000|1200" "${HALOW_ST_CONNECTED_AT[$STA2]}|${HALOW_ST_CHANGED_AT[$STA2]}" "a repeated association line without a disconnect moves the changed-at time but not the connected-since time"
_clock=1500
echo "AP-STA-DISCONNECTED $STA2" >> "$LOG"; halow_st_process_log
assert_eq "|1500" "${HALOW_ST_CONNECTED_AT[$STA2]:-}|${HALOW_ST_CHANGED_AT[$STA2]}" "a disconnect clears connected-since and records the event time"
_clock=1800
echo "AP-STA-CONNECTED $STA2" >> "$LOG"; halow_st_process_log
assert_eq "1800|1800" "${HALOW_ST_CONNECTED_AT[$STA2]}|${HALOW_ST_CHANGED_AT[$STA2]}" "a reconnect starts a new connected-since"

echo "== test_station_lifecycle: the snapshot view =="
new_scenario
LEASES="$HALOW_TEST_TMP/leases"
halow_dhcp_lease_file() { printf '%s' "$LEASES"; }
NEIGH="$HALOW_TEST_TMP/neigh"; FDB="$HALOW_TEST_TMP/fdb"
ip() { case "$1" in neigh) cat "$NEIGH" ;; *) return 1 ;; esac; }
bridge() { case "$1 $2" in "fdb show") cat "$FDB" ;; *) return 1 ;; esac; }
export HALOW_IP=ip HALOW_BRIDGE_CMD=bridge
D1="02:00:00:00:01:01"; D2="02:00:00:00:01:02"; D3="02:00:00:00:01:03"; D4="02:00:00:00:01:04"
snap() { halow_stations_snapshot_lines; }
# one station's block: the S line and what follows up to the next S line
block() { snap | awk -v m="S|$1|" 'index($0, m) == 1 { on = 1; print; next } /^S\|/ { on = 0 } on { print }'; }
cat >> "$LOG" <<EOF
AP-STA-CONNECTED $STA1
AP-STA-CONNECTED $STA2
AP-STA-CONNECTED $STA4
WDS-STA-INTERFACE-ADDED ifname=wlu1.sta1 sta_addr=$STA3
AP-STA-CONNECTED $STA3
EOF
halow_st_process_log
_clock=1003; halow_st_process_log
_clock=2000
echo "AP-STA-DISCONNECTED $STA4" >> "$LOG"; halow_st_process_log
# STA1: unexpired lease. STA2: only an expired lease and a neighbour entry. STA4: offline,
# with an expired lease only. STA3 (four-address): one device learned behind its port.
cat > "$LEASES" <<EOF
3000 $STA1 192.168.90.51 dev1 *
1500 $STA2 192.168.90.52 dev2 *
1500 $STA4 192.168.90.54 dev4 *
3000 $D1 192.168.90.59 behind *
EOF
echo "192.168.90.62 lladdr $STA2 STALE" > "$NEIGH"
printf '%s\n' "$STA3 dev wlu1.sta1 master $BR" "$D1 dev wlu1.sta1 master $BR" "02:00:00:00:00:99 dev wlu1.sta1 master $BR permanent" "33:33:00:00:00:01 dev wlu1.sta1 self permanent" > "$FDB"
assert_eq "S|$STA1|true|ordinary|1000|1000|0|log
SI|192.168.90.51|dhcp|0
S|$STA2|true|ordinary|1000|1000|0|log
SI|192.168.90.62|neighbour|0
S|$STA3|true|wds|1000|1000|0|log
D|$D1
DI|192.168.90.59|dhcp|0
S|$STA4|false|ordinary||2000|0|log" "$(snap)" "ordinary stations show their own address (lease, else neighbour; an expired lease gives nothing); a four-address station shows the device behind its port with that device's address; the offline station keeps its last connection event and has no connected-since"

echo "== test_station_lifecycle: devices behind a four-address station =="
printf '%s\n' "$STA3 dev wlu1.sta1 master $BR" > "$FDB"; : > "$LEASES"; : > "$NEIGH"
assert_eq "S|$STA3|true|wds|1000|1000|0|log" "$(block "$STA3")" "zero devices: only the station's own MAC behind its port, and the station row is still shown"
printf '%s\n' "$STA3 dev wlu1.sta1 master $BR" "$D1 dev wlu1.sta1 master $BR" > "$FDB"
assert_eq "S|$STA3|true|wds|1000|1000|0|log
D|$D1" "$(block "$STA3")" "one device with no lease and no neighbour entry: listed, its address unknown (no address line)"
# three devices; D1 has a lease and a neighbour entry, D2 only a lease, D3 nothing; D4 has a
# lease but is behind no port; STA1 (another station), a multicast address and a permanent
# entry are not devices.
printf '%s\n' "$STA3 dev wlu1.sta1 master $BR" "$D3 dev wlu1.sta1 master $BR" "$D1 dev wlu1.sta1 master $BR" "$D2 dev wlu1.sta1 master $BR" \
    "$D2 dev wlu1.sta1 vlan 1 master $BR" "$STA1 dev wlu1.sta1 master $BR" "01:00:5e:00:00:fb dev wlu1.sta1 master $BR" "02:00:00:00:00:98 dev wlu1.sta1 master $BR permanent" \
    "$D4 dev wlu1.sta2 master $BR" > "$FDB"
cat > "$LEASES" <<EOF
3000 $D1 192.168.90.59 a *
3000 $D2 192.168.90.60 b *
3000 $D4 192.168.90.61 elsewhere *
EOF
echo "192.168.90.59 lladdr $D1 REACHABLE" > "$NEIGH"
assert_eq "S|$STA3|true|wds|1000|1000|0|log
D|$D1
DI|192.168.90.59|dhcp+neighbour|0
D|$D2
DI|192.168.90.60|dhcp|0
D|$D3" "$(block "$STA3")" "several devices: every one behind the port is listed once, sorted, each with the addresses that map to it (a device in two sources is one entry); a lease whose MAC is behind no port is not attributed; another station, a multicast address and a permanent entry are not devices"
assert_eq "0" "$(snap | grep -c "$D4")" "a lease for a MAC that is not behind any port is not shown anywhere"
# two stations, each with its own devices
printf '%s\n' "$STA3 dev wlu1.sta1 master $BR" "$D1 dev wlu1.sta1 master $BR" "$D4 dev wlu1.sta2 master $BR" > "$FDB"
assert_eq "D|$D1
DI|192.168.90.59|dhcp+neighbour|0" "$(block "$STA3" | sed 1d)" "devices are attributed to the station whose port they were learned on"
echo "== test_station_lifecycle: missing, expired and conflicting addresses =="
printf '%s\n' "$STA3 dev wlu1.sta1 master $BR" "$D1 dev wlu1.sta1 master $BR" "$D2 dev wlu1.sta1 master $BR" "$D3 dev wlu1.sta1 master $BR" > "$FDB"
rm -f "$LEASES"; : > "$NEIGH"
assert_eq "S|$STA3|true|wds|1000|1000|0|log
D|$D1
D|$D2
D|$D3" "$(block "$STA3")" "a missing lease file and no neighbour entries: devices listed, addresses unknown, no error"
printf '%s\n' "1500 $D1 192.168.90.59 a *" "1999 $D2 192.168.90.60 b *" "0 $D3 192.168.90.61 c *" > "$LEASES"
assert_eq "S|$STA3|true|wds|1000|1000|0|log
D|$D1
D|$D2
D|$D3
DI|192.168.90.61|dhcp|0" "$(block "$STA3")" "expired leases (before the current time) give no address; an infinite lease (expiry 0) does"
printf '%s\n' "9999 $D1 192.168.90.70 a *" > "$LEASES"
echo "192.168.90.70 lladdr $D2 REACHABLE" > "$NEIGH"
assert_eq "S|$STA3|true|wds|1000|1000|0|log
D|$D1
DI|192.168.90.70|dhcp|1
D|$D2
DI|192.168.90.70|neighbour|1
D|$D3" "$(block "$STA3")" "one address claimed by two MACs (lease for one, neighbour entry for the other): shown on both with the conflict flag, neither preferred"
printf '%s\n' "9999 $D1 192.168.90.71 a *" > "$LEASES"
printf '%s\n' "192.168.90.72 lladdr $D1 REACHABLE" "192.168.90.9 lladdr $D1 FAILED" "192.168.90.8 lladdr $D1 INCOMPLETE" "fe80::1 lladdr $D1 STALE" > "$NEIGH"
assert_eq "S|$STA3|true|wds|1000|1000|0|log
D|$D1
DI|192.168.90.71|dhcp|0
DI|192.168.90.72|neighbour|0
D|$D2
D|$D3" "$(block "$STA3")" "one MAC with two different addresses: both are shown, in order, neither guessed; FAILED, INCOMPLETE and IPv6 neighbour entries are not mappings"
# the station's own MAC in the lease file (a station that is not behind a bridge of its own)
printf '%s\n' "9999 $STA3 192.168.90.80 own *" > "$LEASES"; : > "$NEIGH"
assert_eq "S|$STA3|true|wds|1000|1000|0|log
SI|192.168.90.80|dhcp|0
D|$D1
D|$D2
D|$D3" "$(block "$STA3")" "a lease for the station's own MAC is the station's own address (and the station is not listed as its own device)"
# hostile and malformed input in every source never reaches the output
printf '%s\n' "9999 $D1 192.168.90.99 a *" "9999 <script>alert(1)</script> 192.168.90.98 x *" "9999 $D2 999.1.1.1 x *" "9999 $D3 10.0.0.1;rm x *" \
    "notanumber $D1 192.168.90.97 x *" "99999999999999999999 $D1 192.168.90.96 x *" "9999 $D1" "" "garbage" > "$LEASES"
printf '%s\n' "<img src=x> lladdr $D1 REACHABLE" "192.168.90.95 lladdr <b>$D1 REACHABLE" "192.168.90.94 lladdr zz:zz:zz:zz:zz:zz REACHABLE" "192.168.90.93" > "$NEIGH"
printf '%s\n' "$STA3 dev wlu1.sta1 master $BR" "$D1 dev wlu1.sta1 master $BR" '<script> dev wlu1.sta1 master x' "02:00:00:00:zz:01 dev wlu1.sta1 master $BR" "$D2 dev" > "$FDB"
assert_eq "S|$STA3|true|wds|1000|1000|0|log
D|$D1
DI|192.168.90.99|dhcp|0" "$(block "$STA3")" "malformed lease, neighbour and forwarding lines are skipped; only validated MACs and addresses are printed"
assert_eq "0" "$(snap | grep -c '[<>;]')" "no markup or shell metacharacter reaches the records"
# bounds
printf '%s\n' "$STA3 dev wlu1.sta1 master $BR" "$D1 dev wlu1.sta1 master $BR" "$D2 dev wlu1.sta1 master $BR" "$D3 dev wlu1.sta1 master $BR" > "$FDB"
printf '%s\n' "9999 $D1 192.168.90.11 a *" "9999 $D1 192.168.90.12 a *" > "$LEASES"; : > "$NEIGH"
HALOW_ST_DEVICES_MAX=2; HALOW_ST_IPS_MAX=1; _b="$(block "$STA3")"; HALOW_ST_DEVICES_MAX=16; HALOW_ST_IPS_MAX=4
assert_eq "S|$STA3|true|wds|1000|1000|1|log
D|$D1
DI|192.168.90.11|dhcp|0
D|$D2" "$_b" "devices and addresses are bounded, and the devices left out are counted"
# a lease alone, or a stale fdb entry, never makes a station online or gives an offline station devices
echo "AP-STA-DISCONNECTED $STA3" >> "$LOG"; _clock=2500; halow_st_process_log
assert_eq "S|$STA3|false|wds||2500|0|log" "$(block "$STA3")" "after the station left: offline, no connected-since, and the stale forwarding entries give it no devices"
echo "WDS-STA-INTERFACE-ADDED ifname=wlu1.sta1 sta_addr=$STA3" >> "$LOG"
echo "AP-STA-CONNECTED $STA3" >> "$LOG"; _clock=2600; halow_st_process_log
assert_eq "S|$STA3|true|wds|2600|2600|0|log" "$(block "$STA3" | sed -n 1p)" "after it returned: online again with a new connected-since"
printf '%s\n' "9999 $D1 192.168.90.11 a *" > "$LEASES"
assert_eq "D|$D1
DI|192.168.90.11|dhcp|0" "$(block "$STA3" | sed 1d | sed -n 1,2p)" "...and its devices are found again"
halow_st_set_all_sta "$(printf '%s\n' "$STA1" "flags=[AUTH][ASSOC][AUTHORIZED]" "aid=1" "$STA2" "flags=[AUTH][ASSOC]" "aid=2")"
_snap="$(snap)"
assert_success "all_sta: an authorised station is online" grep -q "^S|$STA1|true|" <<< "$_snap"
assert_success "all_sta: an associated but unauthorised station is not online" grep -q "^S|$STA2|false|ordinary||" <<< "$_snap"
assert_success "all_sta: a station missing from all_sta is not online" grep -q "^S|$STA3|false|" <<< "$_snap"
halow_st_set_all_sta ""
assert_success "an empty all_sta text falls back to the log-derived state" grep -q "^S|$STA2|true|" <<< "$(snap)"
: > "$LEASES"; : > "$NEIGH"
assert_success "a lease alone never makes an offline station online" grep -q "^S|$STA4|false|" <<< "$(snap)"

echo "== test_station_lifecycle: devices are credited only to a four-address station, only when learned =="
printf '%s\n' "$STA3 dev wlu1.sta1 master $BR" "$D1 dev wlu1.sta1 master $BR" "$D2 dev wlu1.sta1 static master $BR" \
    "$D3 dev wlu1.sta1 permanent master $BR" "02:11:22:33:44:55 dev wlu1 master $BR" "02:11:22:33:44:56 dev wlu1 master $BR" > "$FDB"
printf '%s\n' "9999 02:11:22:33:44:55 192.168.90.90 x *" "9999 $D1 192.168.90.91 x *" > "$LEASES"; : > "$NEIGH"
assert_eq "S|$STA3|true|wds|2600|2600|0|log
D|$D1
DI|192.168.90.91|dhcp|0" "$(block "$STA3")" "an administrator-created (static) or permanent forwarding entry is not a learned device"
assert_eq "0" "$(snap | grep -c '02:11:22:33:44:5')" "a MAC learned on the parent port (where the ordinary stations are) is not credited to any station"
assert_eq "S|$STA1|true|ordinary|1000|1000|0|log" "$(block "$STA1")" "an ordinary station never gets devices, even when the parent port has other MACs"
printf '%s\n' "$STA3 dev wlu1.sta1 master $BR" "$STA2 dev wlu1.sta1 master $BR" "$D1 dev wlu1.sta1 master $BR" > "$FDB"
assert_eq "S|$STA3|true|wds|2600|2600|0|log
D|$D1
DI|192.168.90.91|dhcp|0" "$(block "$STA3")" "a station's own MAC and another HaLow station's MAC behind a port are not devices"
for _bad in 256.1.1.1 1.256.1.1 1.1.256.1 1.1.1.256 01.1.1.1 1.1.1 1.1.1.1.1 ""; do
    assert_failure "an address of '$_bad' is not an IPv4 address" _halow_st_is_ipv4 "$_bad"
done
for _good in 0.0.0.0 255.255.255.255 192.168.90.1; do
    assert_success "$_good is an IPv4 address" _halow_st_is_ipv4 "$_good"
done
printf '%s\n' "$STA3 dev wlu1.sta1 master $BR" "$D1 dev wlu1.sta1 master $BR" > "$FDB"
printf '%s\n' "9999 $D1 192.168.90.256 x *" "9999 $D1 256.90.90.1 x *" "9999 $D1 90.256.90.1 x *" "9999 $D1 90.90.256.1 x *" > "$LEASES"
printf '%s\n' "192.168.90.300 lladdr $D1 REACHABLE" "300.1.1.1 lladdr $D1 REACHABLE" > "$NEIGH"
assert_eq "S|$STA3|true|wds|2600|2600|0|log
D|$D1" "$(block "$STA3")" "an address with an octet above 255 is rejected from the leases and from the neighbour table"
echo "== test_station_lifecycle: the documented default bounds (16 devices per station, 4 addresses per MAC) =="
{ printf '%s\n' "$STA3 dev wlu1.sta1 master $BR"; for _i in $(seq 0 16); do printf '02:00:00:00:03:%02x dev wlu1.sta1 master %s\n' "$_i" "$BR"; done; } > "$FDB"
{ for _i in 1 2 3 4 5; do printf '9999 02:00:00:00:03:00 192.168.90.%d x *\n' "$((100 + _i))"; done; } > "$LEASES"; : > "$NEIGH"
_def="$( unset HALOW_ST_DEVICES_MAX HALOW_ST_IPS_MAX; . "$HALOW_LIB_DIR/stations.sh"; halow_st_now() { printf "%s" "$_clock"; }; block "$STA3" )"
assert_eq "16" "$(grep -c '^D|' <<< "$_def")" "with the defaults, 17 devices behind a port are cut to 16"
assert_eq "S|$STA3|true|wds|2600|2600|1|log" "$(sed -n 1p <<< "$_def")" "...and the one left out is counted"
assert_eq "4" "$(grep -c '^DI|' <<< "$_def")" "...and 5 addresses of one MAC are cut to 4"
assert_eq "02:00:00:00:03:00" "$(sed -n 2p <<< "$_def" | cut -d'|' -f2)" "...keeping the first devices in order"

echo "== test_station_lifecycle: a conflict may involve a device that is not listed =="
printf '%s\n' "$STA3 dev wlu1.sta1 master $BR" "$D1 dev wlu1.sta1 master $BR" > "$FDB"
printf '%s\n' "9999 $D1 192.168.90.95 x *" "9999 02:00:00:00:09:09 192.168.90.95 y *" > "$LEASES"; : > "$NEIGH"
assert_eq "S|$STA3|true|wds|2600|2600|0|log
D|$D1
DI|192.168.90.95|dhcp|1" "$(block "$STA3")" "the conflict flag counts every lease and neighbour entry, including a MAC that is behind no station and is not shown"

echo "== test_station_lifecycle: a failed all_sta call never leaves a stale online state =="
_hostapd_out=""
_halow_mgr_hostapd_cli() { if [ "${_hostapd_rc:-0}" -ne 0 ]; then return 1; fi; printf '%s' "$_hostapd_out"; }
HALOW_HOSTAPD_CLI=/bin/true; _hostapd_rc=0
_hostapd_out="$(printf '%s\n' "$STA1" "flags=[AUTH][ASSOC][AUTHORIZED]" "$STA2" "flags=[AUTH][ASSOC][AUTHORIZED]")"
_halow_mgr_all_sta
assert_eq "S|$STA1|true|ordinary|1000|1000|0|hostapd" "$(block "$STA1" | sed -n 1p)" "a successful all_sta: online from hostapd's authorised flag, labelled as such"
assert_eq "S|$STA4|false|ordinary||2000|0|hostapd" "$(block "$STA4" | sed -n 1p)" "...a station hostapd does not list is not online"
_clock=3000
printf '%s\n' "AP-STA-DISCONNECTED $STA1" "AP-STA-CONNECTED $STA4" >> "$LOG"; halow_st_process_log
assert_eq "S|$STA1|true|ordinary||3000|0|hostapd" "$(block "$STA1" | sed -n 1p)" "(control) until the next call the stale hostapd answer still says online (what the failure handling must clear)"
_hostapd_rc=1
_halow_mgr_all_sta
assert_eq "S|$STA1|false|ordinary||3000|0|log" "$(block "$STA1" | sed -n 1p)" "a failed all_sta after a disconnect: the station is offline, from the log, never a stale 'online'"
assert_eq "S|$STA4|true|ordinary|3000|3000|0|log" "$(block "$STA4" | sed -n 1p)" "a failed all_sta after a connect: the station is online, labelled as from the log"
HALOW_HOSTAPD_CLI=/bin/true; _hostapd_rc=0
_hostapd_out="$(printf '%s\n' "$STA1" "flags=[AUTH][ASSOC][AUTHORIZED]")"
_halow_mgr_all_sta
assert_eq "S|$STA1|true|ordinary||3000|0|hostapd" "$(block "$STA1" | sed -n 1p)" "(control) a successful call is in effect again"
HALOW_HOSTAPD_CLI=/nonexistent/hostapd_cli
_halow_mgr_all_sta
assert_eq "S|$STA1|false|ordinary||3000|0|log" "$(block "$STA1" | sed -n 1p)" "no usable hostapd_cli after a good answer: the stale answer is forgotten and the state is from the log"
HALOW_HOSTAPD_CLI=/bin/true; _hostapd_rc=0
_hostapd_out="$(printf '%s\n' "$STA4" "flags=[AUTH][ASSOC][AUTHORIZED]")"
_halow_mgr_all_sta
assert_eq "S|$STA4|true|ordinary|3000|3000|0|hostapd" "$(block "$STA4" | sed -n 1p)" "recovery: the next successful call is used again and labelled hostapd"
assert_eq "S|$STA1|false|ordinary||3000|0|hostapd" "$(block "$STA1" | sed -n 1p)" "...for every station"
_hostapd_out=""
_halow_mgr_all_sta
assert_success "a successful call that lists no station: nobody is online, from hostapd" bash -c '! grep -q "|true|" <<< "$1"' _ "$(snap)"
assert_success "...and every row is labelled hostapd" bash -c '! grep "^S|" <<< "$1" | grep -qv "|hostapd$"' _ "$(snap)"
unset -f _halow_mgr_hostapd_cli; unset _hostapd_rc _hostapd_out; halow_st_set_all_sta ""

echo "== test_station_lifecycle: the records reach the status snapshot =="
cat > "$LEASES" <<EOF
9999 $STA1 192.168.90.51 x *
9999 $D1 192.168.90.59 x *
EOF
printf '%s\n' "$STA3 dev wlu1.sta1 master $BR" "$D1 dev wlu1.sta1 master $BR" "$D2 dev wlu1.sta1 master $BR" > "$FDB"
snap > "$HALOW_TEST_TMP/records"
halow_state_stations_set "$HALOW_TEST_TMP/records"
_json="$HALOW_STATUS_FILE"
_py='import json,sys; d=json.load(open(sys.argv[1])); s={x["mac"]:x for x in d["stations"]}; print(json.dumps([d["schema"], s[sys.argv[2]]["ips"], [(v["mac"], [i["ip"] for i in v["ips"]]) for v in s[sys.argv[3]]["devices"]], s[sys.argv[3]]["connected_since"]]))'
assert_eq "[2, [{\"ip\": \"192.168.90.51\", \"source\": \"dhcp\", \"conflict\": false}], [[\"$D1\", [\"192.168.90.59\"]], [\"$D2\", []]], 2600]" \
    "$(python3 -I -c "$_py" "$_json" "$STA1" "$STA3")" "ordinary address, WDS devices (one with an address, one without) and connected-since arrive in status.json"
unset -f ip bridge halow_dhcp_lease_file snap block
unset HALOW_IP HALOW_BRIDGE_CMD
new_scenario
assert_eq "" "$(halow_stations_snapshot_lines)" "no station: no lines"

echo "== test_station_lifecycle: bounded log rotation =="
new_scenario
RELOGS="$HALOW_TEST_TMP/relogs"; : > "$RELOGS"
# A fake hostapd reopen: one more event still reaches the moved file, then hostapd opens a
# new file at the original path and keeps writing there.
fake_relog() { echo "relog" >> "$RELOGS"; echo "AP-STA-CONNECTED $STA3" >> "$LOG.1"; echo "AP-STA-CONNECTED $STA4" >> "$LOG"; echo "OK"; }
HALOW_ST_RELOG_CMD=(fake_relog)
echo "AP-STA-CONNECTED $STA1" >> "$LOG"
halow_st_process_log
for _i in $(seq 1 40); do echo "wlu1: some other hostapd line $_i padding padding padding" >> "$LOG"; done
echo "AP-STA-CONNECTED $STA2" >> "$LOG"
assert_success "rotation of a large log succeeds" halow_st_rotate_log_if_large 500
assert_eq "relog" "$(cat "$RELOGS")" "hostapd was asked to reopen its log"
assert_file_absent "$LOG.1" "the moved file is drained and removed"
assert_eq "associated|associated|associated" "${HALOW_ST_STATE[$STA2]:-}|${HALOW_ST_STATE[$STA3]:-}|${HALOW_ST_STATE[$STA1]:-}" "events before and during the rotation are all processed (none lost)"
assert_eq "" "${HALOW_ST_STATE[$STA4]:-}" "the event in the new file is not read yet"
halow_st_process_log
assert_eq "associated" "${HALOW_ST_STATE[$STA4]:-}" "...and is read on the next pass, from the start of the new file"
_clock=1003; halow_st_process_log; halow_st_process_log
assert_eq "4" "$(calls | grep -c '^station_added')" "every station is reported exactly once (nothing replayed)"
_size="$(wc -c < "$LOG" | tr -d ' ')"
[ "$_size" -lt 500 ] && _ok=ok || _ok="bad($_size)"
assert_eq "ok" "$_ok" "the log is small again"
assert_success "a log below the limit is left alone" halow_st_rotate_log_if_large 500
assert_eq "1" "$(grep -c relog "$RELOGS")" "...without asking hostapd"

new_scenario
fail_relog() { echo "FAIL"; return 0; }
HALOW_ST_RELOG_CMD=(fail_relog)
for _i in $(seq 1 40); do echo "wlu1: some other hostapd line $_i padding padding padding" >> "$LOG"; done
echo "AP-STA-CONNECTED $STA1" >> "$LOG"
assert_failure "a reopen that hostapd refuses is reported" halow_st_rotate_log_if_large 500
assert_file_exists "$LOG" "...and the log is moved back unchanged"
assert_file_absent "$LOG.1" "...with no moved copy left"
assert_eq "associated" "${HALOW_ST_STATE[$STA1]:-}" "...events up to then were processed"
echo "AP-STA-DISCONNECTED $STA1" >> "$LOG"
halow_st_process_log
assert_eq "offline" "${HALOW_ST_STATE[$STA1]}" "...and reading continues where it was"
new_scenario
HALOW_ST_RELOG_CMD=()
unset HALOW_HOSTAPD_CLI
for _i in $(seq 1 40); do echo "wlu1: some other hostapd line $_i padding padding padding" >> "$LOG"; done
assert_success "with no reopen command configured the log is not rotated (and that is not an error)" halow_st_rotate_log_if_large 500
assert_file_absent "$LOG.1" "...nothing is moved"

echo "== test_station_lifecycle: supervision returns hostapd's own exit status =="
new_scenario
unset -f sleep
( sleep 0.3; exit 7 ) & _sup_pid=$!
{ sleep 0.1; printf 'WDS-STA-INTERFACE-ADDED ifname=wlu1.sta1\nAP-STA-CONNECTED %s\n' "$STA1" >> "$LOG"; } &
halow_st_supervise "$_sup_pid"; _rc=$?
wait 2>/dev/null
assert_eq "7" "$_rc" "supervise returns the supervised process's own exit status"
assert_success "...and handled a station that arrived while it was supervising" grep -q "^station_added wlu1.sta1 $STA1" "$HALOW_DBL_LOG"
sleep() { return 0; }
new_scenario
( true ) & _sup_pid=$!
halow_st_supervise "$_sup_pid"; _rc=$?
assert_eq "0" "$_rc" "supervise returns 0 for a clean exit"

echo "== test_station_lifecycle: backend health keeps the healthy marker honest =="
new_scenario
halow_report_healthy "up"
halow_st_check_health
assert_success "a healthy backend leaves the marker in place" halow_is_healthy
assert_eq "1" "$(grep -c '^health' "$HALOW_DBL_LOG")" "the core really asks the backend (contract operation 'health')"
export HALOW_DBL_HEALTH_RC=1
halow_st_check_health
assert_failure "an unhealthy backend withdraws the marker" halow_is_healthy
unset HALOW_DBL_HEALTH_RC
halow_st_check_health
assert_success "...and it is restored when the backend recovers" halow_is_healthy

echo "== test_station_lifecycle: a backend HARD failure is never success =="
# 1. station_added fails hard: not served, fault recorded, healthy withdrawn, sticky
new_scenario
cat >> "$LOG" <<EOF
WDS-STA-INTERFACE-ADDED ifname=wlu1.sta1 sta_addr=$STA1
AP-STA-CONNECTED $STA1
EOF
halow_st_process_log
halow_report_healthy "up"
export HALOW_DBL_ADD_RC=3
cat >> "$LOG" <<EOF
WDS-STA-INTERFACE-ADDED ifname=wlu1.sta2 sta_addr=$STA2
AP-STA-CONNECTED $STA2
EOF
run_pl; assert_eq "1" "$_pl_rc" "a hard station_added failure is reported as a failure"
assert_eq "0" "${HALOW_ST_SERVED[$STA2]}" "...the station is not recorded as served"
assert_eq "1" "${HALOW_ST_SERVED[$STA1]}" "...the earlier station stays served"
assert_eq "1" "$HALOW_ST_FAULT" "...a fault is recorded"
assert_failure "...and the healthy marker is withdrawn at once" halow_is_healthy
unset HALOW_DBL_ADD_RC
halow_st_check_health
assert_failure "...and the fault is sticky: a healthy backend answer does not restore the marker" halow_is_healthy
# 2. the same for an ordinary station, when its wait ends
new_scenario
export HALOW_DBL_ADD_RC=5
echo "AP-STA-CONNECTED $STA1" >> "$LOG"; halow_st_process_log
_clock=1003
run_pl; assert_eq "1" "$_pl_rc" "a hard failure serving an ordinary station is reported"
assert_eq "1|0" "$HALOW_ST_FAULT|${HALOW_ST_SERVED[$STA1]}" "...fault recorded, not served"
unset HALOW_DBL_ADD_RC
# 3. a later line is still processed after a failing one
new_scenario
export HALOW_DBL_ADD_RC=3
cat >> "$LOG" <<EOF
WDS-STA-INTERFACE-ADDED ifname=wlu1.sta1 sta_addr=$STA1
AP-STA-CONNECTED $STA1
AP-STA-DISCONNECTED $STA1
EOF
run_pl
unset HALOW_DBL_ADD_RC
assert_eq "offline" "${HALOW_ST_STATE[$STA1]}" "the lines after a failing one in the same pass are still processed"
# 4. supervision keeps running after such a fault, and stays unhealthy
new_scenario
unset -f sleep
halow_report_healthy "up"
export HALOW_DBL_ADD_RC=3
( sleep 0.6; exit 9 ) & _sup_pid=$!
{ sleep 0.1; printf 'WDS-STA-INTERFACE-ADDED ifname=wlu1.sta2 sta_addr=%s\nAP-STA-CONNECTED %s\n' "$STA2" "$STA2" >> "$LOG"; } &
halow_st_supervise "$_sup_pid"; _rc=$?
wait 2>/dev/null
sleep() { return 0; }
assert_eq "9" "$_rc" "supervision keeps running through the failure and returns hostapd's own exit status"
assert_eq "1" "$HALOW_ST_FAULT" "...with the fault retained"
assert_failure "...and the healthy marker still withdrawn" halow_is_healthy
unset HALOW_DBL_ADD_RC
# 5. station_removed hard failure is not discarded
new_scenario
cat >> "$LOG" <<EOF
WDS-STA-INTERFACE-ADDED ifname=wlu1.sta1 sta_addr=$STA1
AP-STA-CONNECTED $STA1
EOF
halow_st_process_log
halow_report_healthy "up"
export HALOW_DBL_REMOVE_RC=4
echo "AP-STA-DISCONNECTED $STA1" >> "$LOG"
run_pl; assert_eq "1" "$_pl_rc" "a hard station_removed failure is reported as a failure"
assert_eq "1" "$HALOW_ST_FAULT" "...a fault is recorded"
assert_eq "" "${HALOW_ST_IFACE[$STA1]}" "...the core's own binding is still cleared (state stays consistent)"
assert_eq "offline" "${HALOW_ST_STATE[$STA1]}" "...and the station is recorded offline"
assert_failure "...and the healthy marker is withdrawn" halow_is_healthy
unset HALOW_DBL_REMOVE_RC
# 6. the same through an interface vanishing under a bound station
new_scenario
cat >> "$LOG" <<EOF
WDS-STA-INTERFACE-ADDED ifname=wlu1.sta2 sta_addr=$STA2
AP-STA-CONNECTED $STA2
EOF
halow_st_process_log
halow_report_healthy "up"
export HALOW_DBL_REMOVE_RC=4
echo "WDS-STA-INTERFACE-REMOVED ifname=wlu1.sta2" >> "$LOG"
run_pl; assert_eq "1" "$_pl_rc" "a hard station_removed failure on an interface removal is reported"
assert_eq "" "${HALOW_ST_IFACE[$STA2]}" "...the binding is still dropped"
assert_failure "...and the healthy marker is withdrawn" halow_is_healthy
unset HALOW_DBL_REMOVE_RC

# 7. the fault kind the backend reports is kept with the FIRST fault, across passes
new_scenario
export HALOW_DBL_ADD_RC=1 HALOW_DBL_FAIL_KIND=nm
echo "AP-STA-CONNECTED $STA1" >> "$LOG"; halow_st_process_log; _clock=1003
run_pl
assert_eq "1|nm" "$HALOW_ST_FAULT|$HALOW_ST_FAULT_KIND" "a fault the backend reports as NetworkManager is recorded with kind nm"
assert_success "...and the message carries the backend's reason" grep -q "double: add failed" <<< "$HALOW_ST_FAULT_MSG"
_first="$HALOW_ST_FAULT_MSG"
export HALOW_DBL_FAIL_KIND=other
cat >> "$LOG" <<EOF
WDS-STA-INTERFACE-ADDED ifname=wlu1.sta2 sta_addr=$STA2
AP-STA-CONNECTED $STA2
EOF
run_pl
assert_eq "1|nm|$_first" "$HALOW_ST_FAULT|$HALOW_ST_FAULT_KIND|$HALOW_ST_FAULT_MSG" "a later fault of another kind does not replace the first"
unset HALOW_DBL_ADD_RC HALOW_DBL_FAIL_KIND
cat >> "$LOG" <<EOF
WDS-STA-INTERFACE-ADDED ifname=wlu1.sta3 sta_addr=$STA3
AP-STA-CONNECTED $STA3
EOF
run_pl
assert_eq "1" "${HALOW_ST_SERVED[$STA3]}" "a later pass serves a new station"
assert_eq "1|nm|nm" "$HALOW_ST_FAULT|$HALOW_ST_FAULT_KIND|$HALOW_BACKEND_FAIL_KIND" "...while the fault stays sticky and is still published after the pass"
halow_st_reset "$LOG" wlu1 "$BR"
assert_eq "0||" "$HALOW_ST_FAULT|$HALOW_ST_FAULT_KIND|$HALOW_ST_FAULT_MSG" "only a reset clears it"

echo "== test_station_lifecycle: the earlier routed/NAT backend cannot be attached to the bridge =="
new_scenario noattach
HALOW_BACKEND_NAME=""; halow_backend_register routed_nat
halow_apply_network() { echo "applied" >> "$HALOW_DBL_LOG"; return 0; }
assert_failure "halow_st_attach with routed/NAT fails: it refuses a bridge attachment (2)" halow_st_attach "$BR"
assert_eq "" "$(calls)" "...and nothing was applied"
unset -f halow_apply_network

echo "== test_station_lifecycle: a hard failure under the strict shell options =="
new_scenario
cat >> "$LOG" <<EOF2
WDS-STA-INTERFACE-ADDED ifname=wlu1.sta1 sta_addr=$STA1
AP-STA-CONNECTED $STA1
EOF2
rm -f "$HALOW_DBL_LOG".attached
STRICT_CHILD2="$HALOW_TEST_TMP/strict_child2.sh"
cat > "$STRICT_CHILD2" <<CHILD_EOF
#!/usr/bin/env bash
set -o errexit
set -o errtrace
set -o nounset
set -o pipefail
shopt -s inherit_errexit 2>/dev/null || true
export HALOW_STATE_DIR="$HALOW_STATE_DIR" HALOW_DBL_LOG="$HALOW_DBL_LOG" HALOW_DBL_ADD_RC=3
for lib in constants common ownership validate iface_detect backend stations health; do . "$HALOW_LIB_DIR/\$lib.sh"; done
. "$_TESTS_DIR/doubles/backend_double.sh"
halow_kernel_iface_exists() { return 0; }
halow_st_now() { printf '%s' 1000; }
HALOW_BACKEND_NAME=""
halow_backend_register double
halow_st_reset "$LOG" "wlu1" "$BR"
halow_st_attach "$BR"
if halow_st_process_log; then echo "process_log_rc=0"; else echo "process_log_rc=\$?"; fi
echo "fault=\$HALOW_ST_FAULT served=\${HALOW_ST_SERVED[$STA1]}"
echo CHILD_REACHED_THE_END
CHILD_EOF
_child_out="$(bash "$STRICT_CHILD2" 2>&1)"; _child_rc=$?
assert_eq "0" "$_child_rc" "a hard backend failure does not abort the strict-options process"
assert_success "...the failure is reported to the caller (return 1), not swallowed" grep -q "process_log_rc=1" <<< "$_child_out"
assert_success "...with the fault recorded and the station not served" grep -q "fault=1 served=0" <<< "$_child_out"
assert_success "...and the process reached its last line" grep -q CHILD_REACHED_THE_END <<< "$_child_out"

echo "== test_station_lifecycle: normal non-zero returns under the strict shell options =="
# The manager runs with these options. A non-zero return that is perfectly normal here (the
# backend declining a station with 10, a station with no interface yet, a refused interface
# name, a rotation with no reopen command) must never abort the whole script.
new_scenario
cat >> "$LOG" <<EOF
WDS-STA-INTERFACE-ADDED ifname=wlu1.sta1
AP-STA-CONNECTED $STA1
AP-STA-CONNECTED $STA2
WDS-STA-INTERFACE-ADDED ifname=bogus0 sta_addr=$STA3
AP-STA-CONNECTED $STA3
AP-STA-CONNECTED $STA4
EOF
rm -f "$HALOW_DBL_LOG".attached
STRICT_CHILD="$HALOW_TEST_TMP/strict_child.sh"
cat > "$STRICT_CHILD" <<CHILD_EOF
#!/usr/bin/env bash
set -o errexit
set -o errtrace
set -o nounset
set -o pipefail
shopt -s inherit_errexit 2>/dev/null || true
export HALOW_STATE_DIR="$HALOW_STATE_DIR" HALOW_DBL_LOG="$HALOW_DBL_LOG" HALOW_DBL_MAX_STATIONS=1
for lib in constants common ownership validate iface_detect backend stations health; do . "$HALOW_LIB_DIR/\$lib.sh"; done
. "$_TESTS_DIR/doubles/backend_double.sh"
halow_kernel_iface_exists() { return 0; }
clock=1000
halow_st_now() { printf '%s' "\$clock"; }
HALOW_BACKEND_NAME=""
halow_backend_register double
halow_st_reset "$LOG" "wlu1" "$BR"
halow_st_attach "$BR"
if halow_st_poll; then echo poll1=0; else echo poll1=\$?; fi
clock=1005
halow_st_poll
halow_st_rotate_log_if_large 10
echo "AP-STA-DISCONNECTED $STA1" >> "$LOG"
echo "AP-STA-DISCONNECTED $STA2" >> "$LOG"
halow_st_poll
halow_stations_snapshot_lines > /dev/null
halow_st_check_health
echo "served1=\${HALOW_ST_SERVED[$STA1]} served2=\${HALOW_ST_SERVED[$STA2]} kind4=\${HALOW_ST_KIND[$STA4]} assoc=\$(halow_st_associated_count)"
echo CHILD_REACHED_THE_END
CHILD_EOF
_child_out="$(bash "$STRICT_CHILD" 2>&1)"; _child_rc=$?
assert_eq "0" "$_child_rc" "the strict-options child process exits 0"
assert_success "...the refused interface name made the first poll return 1 without aborting" grep -q "poll1=1" <<< "$_child_out"
assert_success "...and it reached its last line" grep -q CHILD_REACHED_THE_END <<< "$_child_out"
assert_success "...with the expected end state (declined, departed, ordinary, two still associated)" grep -q "served1=0 served2=0 kind4=ordinary assoc=2" <<< "$_child_out"

halow_test_teardown
echo "test_station_lifecycle: $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed"
exit $([ "$HALOW_TEST_FAILURES" -eq 0 ] && echo 0 || echo 1)
