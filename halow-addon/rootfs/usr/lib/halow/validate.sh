#!/usr/bin/env bash
# halow: configuration validation. Every customer-supplied value is validated here
# BEFORE any host mutation (module load, firmware placement, network configuration) is
# attempted — fail closed on anything unexpected, rather than passing an unvalidated value
# into a command string (sed, iptables, hostapd config) that could be manipulated by
# special characters. Radio options (region, mode, bandwidth, channel) are validated by
# radio.sh and the allow-list by allowlist.sh; they are not duplicated here. Development
# build.

# halow_validate_iface_name <name>
# Linux interface names: 1-15 bytes, no '/', no whitespace, no shell/sed-special
# characters. Used for the optional uplink interface and for interface names the add-on
# derives itself.
halow_validate_iface_name() {
    local name="$1"
    if [ -z "$name" ] || [ "${#name}" -gt 15 ]; then
        halow_log_error "validate: interface name '$name' is empty or longer than 15 characters"
        return 1
    fi
    case "$name" in
        *[!a-zA-Z0-9_.-]*)
            halow_log_error "validate: interface name '$name' contains characters outside [A-Za-z0-9_.-]"
            return 1
            ;;
    esac
    return 0
}

# halow_validate_uplink_name <name>
# The optional uplink interface option. Stricter than halow_validate_iface_name: 0 only for
# a plausible physical or network interface name, [A-Za-z0-9][A-Za-z0-9_.-]{0,14} (so never
# empty, '.', '..' or starting with '-'), and never a container-runtime, virtual or
# add-on-owned interface: docker*, hassio (the Supervisor's own network), br-* (container
# networks), veth* (container links), lo, the add-on's own bridge (HALOW_BRIDGE_NAME,
# default halow-br0) and wlu* (the HaLow radio itself). NAT towards one of those would open
# a container network to HaLow clients. Byte-based (LC_ALL=C), never logs more than the
# rejected name, which is not a secret.
halow_validate_uplink_name() {
    local LC_ALL=C
    local name="${1-}" own_bridge="${HALOW_BRIDGE_NAME:-halow-br0}"
    if [ -z "$name" ] || [ "${#name}" -gt 15 ]; then
        halow_log_error "validate: uplink_interface '$name' is empty or longer than 15 characters"
        return 1
    fi
    case "$name" in
        [!A-Za-z0-9]*)
            halow_log_error "validate: uplink_interface '$name' must start with a letter or digit"
            return 1
            ;;
        *[!A-Za-z0-9_.-]*)
            halow_log_error "validate: uplink_interface '$name' contains characters outside [A-Za-z0-9_.-]"
            return 1
            ;;
    esac
    case "$name" in
        docker*|hassio|br-*|veth*|lo|wlu*)
            halow_log_error "validate: uplink_interface '$name' is a container, virtual or HaLow interface, not an uplink"
            return 1
            ;;
    esac
    if [ "$name" = "$own_bridge" ]; then
        halow_log_error "validate: uplink_interface '$name' is the add-on's own bridge, not an uplink"
        return 1
    fi
    return 0
}

# halow_validate_ipv4_cidr <cidr>
# Strict dotted-quad/prefix-length check — not a general-purpose IP library, but enough
# to reject anything that is not exactly N.N.N.N/P with each octet 0-255 and prefix 0-32.
halow_validate_ipv4_cidr() {
    local cidr="$1" ip prefix o1 o2 o3 o4
    case "$cidr" in
        */*) ip="${cidr%/*}"; prefix="${cidr#*/}" ;;
        *) halow_log_error "validate: '$cidr' is not in CIDR form (missing /prefix)"; return 1 ;;
    esac
    case "$prefix" in
        ''|*[!0-9]*) halow_log_error "validate: prefix '$prefix' in '$cidr' is not numeric"; return 1 ;;
    esac
    if [ "$prefix" -lt 0 ] || [ "$prefix" -gt 32 ]; then
        halow_log_error "validate: prefix '$prefix' in '$cidr' is out of range 0-32"
        return 1
    fi
    IFS='.' read -r o1 o2 o3 o4 extra <<< "$ip"
    if [ -n "${extra:-}" ]; then
        halow_log_error "validate: '$ip' has more than four octets"
        return 1
    fi
    for o in "$o1" "$o2" "$o3" "$o4"; do
        case "$o" in
            ''|*[!0-9]*) halow_log_error "validate: '$ip' octet '$o' is not numeric"; return 1 ;;
        esac
        if [ "$o" -lt 0 ] || [ "$o" -gt 255 ]; then
            halow_log_error "validate: '$ip' octet '$o' is out of range 0-255"
            return 1
        fi
    done
    return 0
}

# halow_ipv4_to_int <dotted-quad> — for ordering comparisons (DHCP range start < end).
halow_ipv4_to_int() {
    local ip="$1" a b c d
    IFS='.' read -r a b c d <<< "$ip"
    echo $(( (a * 16777216) + (b * 65536) + (c * 256) + d ))
}

# halow_ipv4_mask_from_prefix <0-32> — prints the prefix's own 32-bit mask as a decimal
# integer (e.g. 24 -> 4294967040).
halow_ipv4_mask_from_prefix() {
    local prefix="$1" mask=0 i
    for (( i = 0; i < prefix; i++ )); do
        mask=$(( mask | (1 << (31 - i)) ))
    done
    echo "$mask"
}

# halow_validate_dhcp_range <start_ip> <end_ip> <cidr>
# Real IPv4 mask containment, not a textual octet-prefix guess: both addresses must be
# plain dotted-quad (no /prefix), correctly ordered, strictly inside the usable host
# range for <cidr>'s own prefix (excluding the network and broadcast addresses), and
# must not equal the configured gateway address (<cidr>'s own host part) — correct for
# any prefix 0-32, not just /24 (an earlier version of this function compared only the
# first three octets while accepting any prefix, which rejected valid ranges for
# broader prefixes and accepted invalid ones for narrower prefixes alike).
halow_validate_dhcp_range() {
    local start="$1" end="$2" cidr="$3"
    for ip in "$start" "$end"; do
        case "$ip" in */*) halow_log_error "validate: '$ip' must be a plain address, not CIDR"; return 1 ;; esac
        if ! halow_validate_ipv4_cidr "${ip}/32"; then
            return 1
        fi
    done

    local gw="${cidr%/*}" prefix="${cidr#*/}"
    local start_i end_i gw_i mask net_i bcast_i
    start_i="$(halow_ipv4_to_int "$start")"
    end_i="$(halow_ipv4_to_int "$end")"
    gw_i="$(halow_ipv4_to_int "$gw")"

    if [ "$start_i" -ge "$end_i" ]; then
        halow_log_error "validate: dhcp_range_start ($start) must be before dhcp_range_end ($end)"
        return 1
    fi

    mask="$(halow_ipv4_mask_from_prefix "$prefix")"
    net_i=$(( gw_i & mask ))
    bcast_i=$(( net_i | ((~mask) & 0xFFFFFFFF) ))

    local ip_i label
    for ip_i in "$start_i:$start" "$end_i:$end"; do
        local val="${ip_i%%:*}" label="${ip_i#*:}"
        if [ "$val" -le "$net_i" ] || [ "$val" -ge "$bcast_i" ]; then
            halow_log_error "validate: $label is not a usable host address for $cidr (outside the network/broadcast-excluded range)"
            return 1
        fi
        if [ "$val" -eq "$gw_i" ]; then
            halow_log_error "validate: $label must not be the same as the configured gateway address $gw"
            return 1
        fi
    done
    return 0
}

# halow_validate_ssid <ssid>
# 1-32 bytes (the IEEE 802.11 SSID length limit), and excludes characters that would
# break the hostapd config line it is substituted into regardless of the substitution
# method used.
#
# Byte length, not character length (fixed during development): bash's own `${#ssid}`
# counts CHARACTERS under a multibyte-aware locale (e.g. UTF-8, the common default) —
# a single multibyte character (an accented letter, an emoji, ...) counts as one
# "character" there even though it occupies 2-4 BYTES on the wire, so a multibyte SSID
# could pass this check while actually exceeding the real 32-BYTE IEEE 802.11 limit.
# `wc -c` always counts raw bytes, regardless of locale.
halow_validate_ssid() {
    local ssid="$1" len
    len="$(printf '%s' "$ssid" | wc -c)"
    if [ "$len" -lt 1 ] || [ "$len" -gt 32 ]; then
        halow_log_error "validate: SSID length must be 1-32 bytes (got $len)"
        return 1
    fi
    case "$ssid" in
        *$'\n'*|*$'\r'*)
            halow_log_error "validate: SSID must not contain newline/carriage-return characters"
            return 1
            ;;
        *'\'*)
            # Rejected defensively, not because HaLow forbids it in an SSID: this value
            # is later passed through `awk -v`, whose own -v assignment parsing applies
            # backslash-escape processing (\n, \t, ...) to the string — a literal
            # backslash sequence here could otherwise be converted into a real newline
            # or other control character downstream, reopening the exact injection this
            # validation exists to close.
            halow_log_error "validate: SSID must not contain a backslash character"
            return 1
            ;;
    esac
    return 0
}

# halow_validate_passphrase <passphrase>
# Printable ASCII only (bytes 32-126) and 12-63 BYTES: the add-on's own minimum of 12
# (stricter than the 8 that WPA3-Personal (SAE) itself allows) and hostapd's limit of 63
# bytes for a passphrase. Counted with LC_ALL=C so a multibyte character counts as its
# bytes, never as one character; anything outside printable ASCII (control characters,
# newline, carriage return, any byte above 126) is refused. Never logs the value itself
# (only its byte length). Plain assignments, deliberately not overridable from the
# environment: this is a security policy, not a path.
HALOW_PASSPHRASE_MIN_LEN=12
HALOW_PASSPHRASE_MAX_LEN=63
halow_validate_passphrase() {
    local LC_ALL=C
    local passphrase="${1-}" len
    len=${#passphrase}
    if [ "$len" -lt "$HALOW_PASSPHRASE_MIN_LEN" ] || [ "$len" -gt "$HALOW_PASSPHRASE_MAX_LEN" ]; then
        halow_log_error "validate: wifi_passphrase must be ${HALOW_PASSPHRASE_MIN_LEN}-${HALOW_PASSPHRASE_MAX_LEN} bytes of printable ASCII (got $len bytes)"
        return 1
    fi
    case "$passphrase" in
        *[!\ -~]*)
            halow_log_error "validate: wifi_passphrase must contain only printable ASCII characters (letters, digits, punctuation, space)"
            return 1
            ;;
    esac
    return 0
}
