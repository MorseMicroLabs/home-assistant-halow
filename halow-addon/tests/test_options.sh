#!/usr/bin/env bash
# options.sh: loading (environment and bashio), defaults, the radio model (a saved channel
# never influences automatic mode; manual mode requires one) and every validation path in
# its documented order.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh
. ./helpers_lifecycle.sh

echo "== test_options =="

fresh() {
    # forget every stub override of the previous case
    local v
    for v in ${!HL_RC_*} ${!HL_RCSEQ_*}; do unset "$v"; done
    . ./helpers_lifecycle.sh
    hl_setup
    hl_child_load
}
validate_quiet() { halow_options_load; halow_options_validate 2>"$HL_DIR/err.log"; }
expect_error() {   # <code> <option> <message>
    if validate_quiet; then _r=0; else _r=$?; fi
    assert_eq "1" "$_r" "$3: validation fails"
    assert_eq "$1" "$HALOW_CFG_ERROR_CODE" "$3: code $1"
    assert_eq "$2" "$HALOW_CFG_ERROR_OPTION" "$3: option $2"
}

echo "-- a complete valid set (environment form) --"
fresh
assert_success "valid" validate_quiet
assert_eq "AU" "$HALOW_CFG_REGION" "region"
assert_eq "manual" "$HALOW_CFG_RADIO_MODE" "radio_mode"
assert_eq "28" "$HALOW_CFG_CHANNEL" "manual channel kept"
assert_eq "101" "$HALOW_CFG_MAX_STATIONS" "max stations from the pool"
assert_eq "" "$HALOW_CFG_ERROR_CODE" "no error code"
halow_test_teardown

echo "-- defaults: radio_mode automatic, bandwidth the development default --"
fresh
unset HALOW_OPT_RADIO_MODE HALOW_OPT_BANDWIDTH HALOW_OPT_CHANNEL
HALOW_DEFAULT_BANDWIDTH_MHZ=1
halow_options_load
assert_eq "automatic" "$HALOW_CFG_RADIO_MODE" "radio_mode defaults to automatic"
assert_eq "1" "$HALOW_CFG_BANDWIDTH" "bandwidth defaults to HALOW_DEFAULT_BANDWIDTH_MHZ"
HALOW_DEFAULT_BANDWIDTH_MHZ=2
halow_options_load
assert_eq "2" "$HALOW_CFG_BANDWIDTH" "the default follows the constant"
halow_test_teardown

echo "-- bandwidth accepted as 1 or \"1\" --"
for v in '1' '"1"' "'1'" ' 1 ' '"4"'; do
    fresh
    export HALOW_OPT_BANDWIDTH="$v"
    assert_success "bandwidth [$v] valid" validate_quiet
    assert_eq "$(tr -dc '0-9' <<< "$v")" "$HALOW_CFG_BANDWIDTH" "bandwidth [$v] read as a number"
    halow_test_teardown
done
fresh; export HALOW_OPT_BANDWIDTH="1MHz"; expect_error CONFIG_INVALID bandwidth "bandwidth 1MHz"; halow_test_teardown
fresh; export HALOW_OPT_BANDWIDTH="-1"; expect_error CONFIG_INVALID bandwidth "bandwidth -1"; halow_test_teardown

echo "-- automatic mode ignores a saved channel; it can never reach the radio choice --"
fresh
export HALOW_OPT_RADIO_MODE="automatic" HALOW_OPT_CHANNEL="99"
assert_success "automatic with a saved (even invalid) channel is valid" validate_quiet
assert_eq "" "$HALOW_CFG_CHANNEL" "HALOW_CFG_CHANNEL is empty in automatic mode"
assert_eq "99" "$HALOW_CFG_CHANNEL_SAVED" "the saved value is kept for diagnostics only"
assert_success "the radio validator saw automatic mode with no channel" grep -q '^halow_radio_validate AU automatic 1 *$' "$HL_DIR/calls.log"
assert_failure "the saved channel was never passed to any radio function" grep -q -w '99' "$HL_DIR/calls.log"
halow_test_teardown

echo "-- manual mode requires a valid channel --"
fresh; export HALOW_OPT_CHANNEL=""; expect_error CONFIG_INVALID channel "manual without a channel"; halow_test_teardown
fresh; export HALOW_OPT_CHANNEL="abc"; expect_error CONFIG_INVALID channel "manual with a non-numeric channel"; halow_test_teardown
fresh; export HALOW_OPT_CHANNEL="99"; expect_error CONFIG_INVALID channel "manual with channel 99 (invalid for the region)"
assert_success "the reason from the radio validator is kept" grep -q 'channel 99 is not valid' <<< "$HALOW_CFG_ERROR_REASON"
halow_test_teardown
fresh; export HALOW_OPT_CHANNEL="30"; assert_success "manual with channel 30 is valid" validate_quiet
assert_success "the radio validator saw manual with 30" grep -q '^halow_radio_validate AU manual 1 30$' "$HL_DIR/calls.log"
halow_test_teardown

echo "-- the radio validator's OPTION= line names the option --"
fresh
hl_act_halow_radio_validate() { printf 'OPTION=bandwidth REASON=8 MHz is not offered\n'; HL_ACT_RC=1; }
expect_error CONFIG_INVALID bandwidth "radio validator rejects the bandwidth"
assert_eq "8 MHz is not offered" "$HALOW_CFG_ERROR_REASON" "the reason text is taken from the validator"
halow_test_teardown
fresh
hl_act_halow_radio_validate() { printf 'garbage\n'; HL_ACT_RC=1; }
expect_error CONFIG_INVALID channel "an unparseable validator line in manual mode names the channel"
halow_test_teardown

echo "-- each validation path --"
fresh; export HALOW_OPT_WIFI_SSID=""; expect_error CONFIG_INVALID wifi_ssid "empty SSID"; halow_test_teardown
fresh; export HALOW_OPT_WIFI_SSID="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; expect_error CONFIG_INVALID wifi_ssid "33-byte SSID"; halow_test_teardown
fresh; export HALOW_OPT_WIFI_PASSPHRASE=""; expect_error CONFIG_INVALID wifi_passphrase "missing passphrase"; halow_test_teardown
fresh; export HALOW_OPT_WIFI_PASSPHRASE="short"; expect_error CONFIG_INVALID wifi_passphrase "short passphrase"
assert_failure "the passphrase value is never logged" grep -q 'short' "$HL_DIR/err.log"
halow_test_teardown
fresh; export HALOW_OPT_REGION=""; expect_error REGION_UNVALIDATED region "missing region"; halow_test_teardown
fresh; HL_RC_halow_radio_profile_exists=1; expect_error REGION_UNVALIDATED region "region without a validated profile"; halow_test_teardown
fresh; export HALOW_OPT_RADIO_MODE="auto"; expect_error CONFIG_INVALID radio_mode "unknown radio mode"
assert_success "the radio_mode error uses the label with the key in parentheses" grep -q -F "Channel selection mode (radio_mode) must be automatic or manual" "$HL_DIR/err.log"
halow_test_teardown
fresh; export HALOW_OPT_HALOW_SUBNET_CIDR="192.168.90.1"; expect_error CONFIG_INVALID halow_subnet_cidr "subnet without prefix"; halow_test_teardown
fresh; export HALOW_OPT_HALOW_SUBNET_CIDR="300.1.1.1/24"; expect_error CONFIG_INVALID halow_subnet_cidr "subnet octet out of range"; halow_test_teardown
fresh; export HALOW_OPT_DHCP_RANGE_START="x"; expect_error CONFIG_INVALID dhcp_range_start "bad DHCP start"; halow_test_teardown
fresh; export HALOW_OPT_DHCP_RANGE_END=""; expect_error CONFIG_INVALID dhcp_range_end "missing DHCP end"; halow_test_teardown
fresh; export HALOW_OPT_DHCP_RANGE_START="192.168.90.200"; expect_error CONFIG_INVALID dhcp_range_start "start after end"; halow_test_teardown
fresh; export HALOW_OPT_DHCP_RANGE_START="192.168.91.10"; expect_error CONFIG_INVALID dhcp_range_start "start outside the subnet"; halow_test_teardown
fresh; HL_RC_halow_subnet_collision=1; hl_act_halow_subnet_collision() { echo "overlaps 192.168.90.0/24 on end0"; }
expect_error CONFIG_INVALID halow_subnet_cidr "subnet collides with a host network"
assert_success "the collision reason is included" grep -q 'overlaps 192.168.90.0/24 on end0' <<< "$HALOW_CFG_ERROR_REASON"
halow_test_teardown
fresh; hl_act_halow_max_stations() { printf '0'; }; expect_error CONFIG_INVALID dhcp_range_end "an empty DHCP pool"; halow_test_teardown
fresh; export HALOW_OPT_ALLOWED_PORTS="tcp/80 tcp/22"
hl_act_halow_allowlist_validate() { local a; shift; for a in "$@"; do [ "$a" = "tcp/22" ] && { echo "$a"; HL_ACT_RC=1; return 0; }; done; }
expect_error CONFIG_INVALID allowed_ports "an allow-list entry is rejected"
assert_success "the offending entry is named" grep -q "tcp/22" <<< "$HALOW_CFG_ERROR_REASON"
halow_test_teardown
fresh; export HALOW_OPT_UPLINK_INTERFACE="bad name!"; expect_error CONFIG_INVALID uplink_interface "invalid uplink name"; halow_test_teardown
fresh; export HALOW_OPT_UPLINK_INTERFACE="end0"; assert_success "an explicit valid uplink name" validate_quiet; assert_eq "end0" "$HALOW_CFG_UPLINK" "uplink kept"; halow_test_teardown

echo "-- the uplink rule (the real validator): no container, virtual or HaLow network can be named as the uplink --"
for u in . .. -x hassio docker0 docker1 veth12ab br-0123abcd lo halow-br0 wlu1 "a/b" "toolongname12345"; do
    fresh; export HALOW_OPT_UPLINK_INTERFACE="$u"; expect_error CONFIG_INVALID uplink_interface "uplink '$u' refused"; halow_test_teardown
done
for u in end0 eth0 enp1s0 wlan0; do
    fresh; export HALOW_OPT_UPLINK_INTERFACE="$u"; assert_success "uplink '$u' accepted" validate_quiet; halow_test_teardown
done

echo "-- ordering: the first error in the documented order wins --"
fresh; export HALOW_OPT_WIFI_SSID="" HALOW_OPT_WIFI_PASSPHRASE="x" HALOW_OPT_REGION=""
expect_error CONFIG_INVALID wifi_ssid "SSID before passphrase and region"; halow_test_teardown
fresh; export HALOW_OPT_WIFI_PASSPHRASE="x" HALOW_OPT_REGION=""
expect_error CONFIG_INVALID wifi_passphrase "passphrase before region"; halow_test_teardown
fresh; export HALOW_OPT_REGION="" HALOW_OPT_RADIO_MODE="bogus"
expect_error REGION_UNVALIDATED region "region before radio mode"; halow_test_teardown
fresh; export HALOW_OPT_CHANNEL="99" HALOW_OPT_HALOW_SUBNET_CIDR="bad"
expect_error CONFIG_INVALID channel "radio choice before subnet"; halow_test_teardown
fresh; export HALOW_OPT_HALOW_SUBNET_CIDR="bad" HALOW_OPT_ALLOWED_PORTS="tcp/22"; HL_RC_halow_allowlist_validate=1
expect_error CONFIG_INVALID halow_subnet_cidr "subnet before allow-list"; halow_test_teardown
fresh; HL_RC_halow_subnet_collision=1; HL_RC_halow_allowlist_validate=1
expect_error CONFIG_INVALID halow_subnet_cidr "collision before allow-list"; halow_test_teardown
fresh; HL_RC_halow_allowlist_validate=1; export HALOW_OPT_UPLINK_INTERFACE="bad name!"
expect_error CONFIG_INVALID allowed_ports "allow-list before uplink"; halow_test_teardown

echo "-- allowed_ports parsing --"
fresh; export HALOW_OPT_ALLOWED_PORTS="tcp/80 udp/5683"; halow_options_load
assert_eq "tcp/80 udp/5683" "$HALOW_CFG_ALLOWED_PORTS" "space-separated"
export HALOW_OPT_ALLOWED_PORTS=$'tcp/80\nudp/5683\n'; halow_options_load
assert_eq "tcp/80 udp/5683" "$HALOW_CFG_ALLOWED_PORTS" "one per line (the bashio list form)"
export HALOW_OPT_ALLOWED_PORTS='["tcp/80","udp/5683"]'; halow_options_load
assert_eq "tcp/80 udp/5683" "$HALOW_CFG_ALLOWED_PORTS" "a JSON-style list"
export HALOW_OPT_ALLOWED_PORTS=""; halow_options_load
assert_eq "" "$HALOW_CFG_ALLOWED_PORTS" "empty by default"
: > "$HL_DIR/calls.log"; export HALOW_OPT_ALLOWED_PORTS="tcp/80 udp/5683"
validate_quiet
assert_success "each entry reaches the allow-list validator as its own argument" grep -q '^halow_allowlist_validate tcp/80 udp/5683$' "$HL_DIR/calls.log"
halow_test_teardown

echo "-- bashio is used when present ('null' is empty) --"
fresh
unset HALOW_OPT_REGION
bashio::config() {
    case "$1" in
        region) echo "AU" ;; radio_mode) echo "manual" ;; bandwidth) echo "1" ;; channel) echo "28" ;;
        wifi_ssid) echo "FromBashio" ;; wifi_passphrase) echo "bashio-passphrase-12" ;; halow_subnet_cidr) echo "10.20.0.1/24" ;;
        dhcp_range_start) echo "10.20.0.10" ;; dhcp_range_end) echo "10.20.0.20" ;; uplink_interface) echo "null" ;;
        allowed_ports) printf 'tcp/8123\n' ;; *) echo "null" ;;
    esac
}
export HALOW_OPT_WIFI_SSID="FromEnvironment"
assert_success "valid through bashio" validate_quiet
assert_eq "FromBashio" "$HALOW_CFG_WIFI_SSID" "bashio wins over the environment"
assert_eq "" "$HALOW_CFG_UPLINK" "'null' reads as empty"
assert_eq "tcp/8123" "$HALOW_CFG_ALLOWED_PORTS" "list from bashio"
assert_eq "28" "$HALOW_CFG_CHANNEL" "channel from bashio"
unset -f bashio::config
halow_test_teardown

echo "-- a missing validator is an internal error, never a silent pass --"
fresh
unset -f halow_subnet_collision
expect_error INTERNAL_ERROR "" "a validator function is missing"
halow_test_teardown

echo "test_options: $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed"
exit $([ "$HALOW_TEST_FAILURES" -eq 0 ] && echo 0 || echo 1)
