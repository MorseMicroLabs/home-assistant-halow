#!/usr/bin/env bash
# Tests validate.sh: interface names, IPv4 CIDR, DHCP range ordering/subnet sanity,
# SSID, and passphrase — including hostile/special-character inputs that must be
# rejected rather than silently passed through to sed/awk/iptables/hostapd.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh

echo "== test_validate =="
halow_test_setup

# --- Interface names ---
assert_success "a normal interface name is accepted" halow_validate_iface_name "wlu1"
assert_failure "an interface name with a slash is rejected" halow_validate_iface_name "wlu1/evil"
assert_failure "an interface name with a space is rejected" halow_validate_iface_name "wlu1 evil"
assert_failure "an interface name longer than 15 characters is rejected" halow_validate_iface_name "abcdefghijklmnopqrstuvwxyz"
assert_failure "an empty interface name is rejected" halow_validate_iface_name ""
assert_failure "a semicolon-injection-shaped interface name is rejected" halow_validate_iface_name "eth0;rm -rf /"

# --- Uplink interface option: plausible physical/network names only ---
for good in end0 eth0 enp1s0 wlan0 eth0.10 en_x-1 abcdefghijklmno 0eth; do
    assert_success "uplink_interface '$good' is accepted" halow_validate_uplink_name "$good"
done
for bad in "" . .. -eth0 _eth0 .eth0 hassio docker0 docker_gwbridge br-0a1b2c3d4e5f veth12ab34c lo \
           halow-br0 wlu1 wlu1.sta1 abcdefghijklmnop "eth 0" "eth0/1" 'eth0;x' "$(printf 'eth0\nx')" "ethé"; do
    assert_failure "uplink_interface '$(printf '%q' "$bad")' is rejected" halow_validate_uplink_name "$bad"
done
assert_success "a name that only begins like a reserved one is accepted (lo0 is not lo)" halow_validate_uplink_name lo0
assert_success "hassio1 is not the Supervisor network name and is accepted" halow_validate_uplink_name hassio1
HALOW_BRIDGE_NAME=custom-br7
assert_failure "the add-on's own bridge is rejected under its configured name" halow_validate_uplink_name custom-br7
assert_success "halow-br0 is accepted only when it is not the add-on's bridge (the check follows HALOW_BRIDGE_NAME)" halow_validate_uplink_name halow-br0
HALOW_BRIDGE_NAME=halow-br0
_log="$(halow_validate_uplink_name hassio 2>&1 || true)"
assert_success "the rejection names the option" grep -q "uplink_interface 'hassio'" <<< "$_log"
assert_success "the uplink check needs no subshell to be strict (it runs under errexit as a condition)" \
    bash -c 'set -euo pipefail; . "$1/common.sh"; . "$1/validate.sh"; if halow_validate_uplink_name docker0 2>/dev/null; then exit 1; fi; halow_validate_uplink_name end0' _ "$HALOW_LIB_DIR"

# --- IPv4 CIDR ---
assert_success "a normal CIDR is accepted" halow_validate_ipv4_cidr "192.168.90.1/24"
assert_failure "a CIDR missing the prefix is rejected" halow_validate_ipv4_cidr "192.168.90.1"
assert_failure "a CIDR with an out-of-range octet is rejected" halow_validate_ipv4_cidr "192.168.90.999/24"
assert_failure "a CIDR with an out-of-range prefix is rejected" halow_validate_ipv4_cidr "192.168.90.1/99"
assert_failure "a CIDR with a non-numeric octet is rejected" halow_validate_ipv4_cidr "192.168.90.x/24"
assert_failure "a CIDR with five octets is rejected" halow_validate_ipv4_cidr "192.168.90.1.2/24"

# --- DHCP range ---
assert_success "a sane DHCP range inside the configured subnet is accepted" \
    halow_validate_dhcp_range "192.168.90.50" "192.168.90.150" "192.168.90.1/24"
assert_failure "a reversed DHCP range (start after end) is rejected" \
    halow_validate_dhcp_range "192.168.90.150" "192.168.90.50" "192.168.90.1/24"
assert_failure "an equal start/end DHCP range is rejected" \
    halow_validate_dhcp_range "192.168.90.50" "192.168.90.50" "192.168.90.1/24"
assert_failure "a DHCP range outside the configured subnet is rejected" \
    halow_validate_dhcp_range "10.0.0.50" "10.0.0.150" "192.168.90.1/24"
assert_failure "a DHCP range value given as CIDR (not a plain address) is rejected" \
    halow_validate_dhcp_range "192.168.90.50/32" "192.168.90.150" "192.168.90.1/24"

# --- SSID ---
assert_success "a normal SSID is accepted" halow_validate_ssid "HaLow-Network"
assert_failure "an empty SSID is rejected" halow_validate_ssid ""
assert_failure "an SSID longer than 32 bytes is rejected" halow_validate_ssid "this-ssid-is-definitely-longer-than-32-bytes"

# Regression test: byte length, not character length. "é" is a single CHARACTER but 2
# BYTES in UTF-8 — under the original `${#ssid}` (character-counting, in a UTF-8 locale)
# implementation, an SSID of 17 such characters (34 real bytes, genuinely over the real
# IEEE 802.11 32-BYTE limit) would have been wrongly ACCEPTED, since 17 <= 32 when
# counted as characters. Exact boundaries, built from a real 2-byte UTF-8 character:
ssid_16_multibyte_chars="$(printf 'é%.0s' $(seq 1 16))"    # 16 chars, exactly 32 bytes
ssid_17_multibyte_chars="$(printf 'é%.0s' $(seq 1 17))"    # 17 chars, 34 bytes — over
assert_success "an SSID of exactly 32 bytes built from 2-byte UTF-8 characters (16 chars) is accepted" \
    halow_validate_ssid "$ssid_16_multibyte_chars"
assert_failure "an SSID of 17 multibyte characters (34 bytes) is rejected, even though 17 <= 32 CHARACTERS (the actual regression this fix closes)" \
    halow_validate_ssid "$ssid_17_multibyte_chars"
assert_failure "an SSID containing a newline is rejected" halow_validate_ssid "$(printf 'Evil\nssid=injected')"
assert_failure "an SSID containing a backslash is rejected (awk -v escape-processing defence)" halow_validate_ssid 'Evil\nSSID'
assert_success "an SSID containing a forward slash is accepted (not sed-substituted any more)" halow_validate_ssid "My/Network"
assert_success "an SSID containing an ampersand is accepted (not sed-substituted any more)" halow_validate_ssid "My&Network"

# --- Passphrase (minimum 12, maximum 63) ---
_rep() { printf "${1}%.0s" $(seq 1 "$2"); }
assert_success "a valid passphrase is accepted" halow_validate_passphrase "a-valid-passphrase"
assert_success "a passphrase of exactly 12 characters is accepted (the minimum)" halow_validate_passphrase "$(_rep b 12)"
assert_failure "a passphrase of 11 characters is rejected (one below the minimum)" halow_validate_passphrase "$(_rep b 11)"
assert_failure "an 8-character passphrase (the old minimum) is now rejected" halow_validate_passphrase "eightchr"
assert_failure "a passphrase shorter than 8 characters is rejected" halow_validate_passphrase "short"
assert_failure "an empty passphrase is rejected" halow_validate_passphrase ""
assert_success "a passphrase of exactly 63 characters is accepted (the maximum)" halow_validate_passphrase "$(_rep c 63)"
assert_failure "a passphrase longer than 63 characters is rejected" halow_validate_passphrase "$(_rep a 64)"
assert_failure "a passphrase containing a newline is rejected" halow_validate_passphrase "$(printf 'evil-long\npassphrase')"
assert_failure "a passphrase containing a carriage return is rejected" halow_validate_passphrase "$(printf 'evil-long\rpassphrase')"
assert_eq "12" "$HALOW_PASSPHRASE_MIN_LEN" "the minimum is a fixed 12"
# Bytes and printable ASCII (hostapd's limit is 63 bytes).
assert_success "every printable ASCII character, including space and tilde, is accepted" \
    halow_validate_passphrase ' !"#$%&()*+,-./09:;<=>?@AZ[\]^_`az{|}~'
assert_failure "a tab is rejected (not printable ASCII)" halow_validate_passphrase "$(printf 'tab\there-long-enough')"
assert_failure "a DEL byte (127) is rejected" halow_validate_passphrase "$(printf 'del\177here-long-enough')"
assert_failure "an escape byte is rejected" halow_validate_passphrase "$(printf 'esc\033here-long-enough')"
assert_failure "an accented letter is rejected even when the length is fine" halow_validate_passphrase "passphrase-é-long"
_pp_mb="$(printf 'é%.0s' $(seq 1 32))"    # 32 characters, 64 bytes
assert_failure "32 two-byte characters (64 bytes) are rejected: the limit is bytes, not characters" halow_validate_passphrase "$_pp_mb"
_log="$(LC_ALL=C.UTF-8 halow_validate_passphrase "$_pp_mb" 2>&1 || true)"
assert_success "under a UTF-8 locale the length is still counted in bytes (the message reports 64 bytes)" grep -qF "got 64 bytes" <<< "$_log"
for loc in C.UTF-8 en_US.UTF-8; do
    assert_failure "the byte rule holds when the caller's locale is $loc" \
        env LC_ALL="$loc" bash -c '. "$1/common.sh"; . "$1/validate.sh"; halow_validate_passphrase "$2"' _ "$HALOW_LIB_DIR" "$(printf 'é%.0s' $(seq 1 12))"
done
assert_success "the locale of the caller is restored after the check" \
    env LC_ALL=C.UTF-8 bash -c '. "$1/common.sh"; . "$1/validate.sh"; halow_validate_passphrase abcdefghijkl; [ "$LC_ALL" = C.UTF-8 ]' _ "$HALOW_LIB_DIR"
_pp_long="$(printf 'Sample-%s-xyz' Value)"
_pp_short="$(printf 'S-%s' xyz1)"
_log="$(halow_validate_passphrase "$_pp_short" 2>&1 || true)"
assert_success "the rejection message names the option and the rule" grep -q "wifi_passphrase must be 12-63 bytes of printable ASCII" <<< "$_log"
_log="$(halow_validate_passphrase "Sample-é-$_pp_long" 2>&1 || true)"
assert_failure "the printable-ASCII rejection never contains the passphrase itself" grep -qF "$_pp_long" <<< "$_log"
assert_failure "the rejection message never contains the passphrase itself" grep -qF "$_pp_short" <<< "$_log"
_log="$(halow_validate_passphrase "$(printf '%s\n%s' "$_pp_long" "$_pp_long")" 2>&1 || true)"
assert_failure "the newline rejection never contains the passphrase itself" grep -qF "$_pp_long" <<< "$_log"
# Re-sourcing restores the policy even if a caller changed the variable in between.
HALOW_PASSPHRASE_MIN_LEN=4
. "$HALOW_LIB_DIR/validate.sh"
assert_failure "re-sourcing validate.sh restores the fixed minimum (an environment value cannot lower it)" halow_validate_passphrase "abcdefgh"
assert_failure "the minimum is not taken from the environment" \
    env HALOW_PASSPHRASE_MIN_LEN=1 bash -c '. "$1/common.sh"; . "$1/validate.sh"; halow_validate_passphrase abc' _ "$HALOW_LIB_DIR"

halow_test_teardown
echo "test_validate: $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed"
exit $([ "$HALOW_TEST_FAILURES" -eq 0 ] && echo 0 || echo 1)
