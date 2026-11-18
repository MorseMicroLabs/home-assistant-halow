#!/usr/bin/env bash
# halow: uplink detection, subnet collision checks and DHCP pool sizing (IPv4 only).
#
# The uplink is exactly one interface: the interface of the default route at start. No
# default route, or several default routes through different interfaces, is reported as
# a failure (the caller raises UPLINK_UNAVAILABLE) rather than guessed.
#
# Defines functions and constants only; nothing runs when sourced. Every external command
# is called through HALOW_IP (default `ip`) so the tests can substitute a fake.
# Depends on validate.sh (halow_validate_ipv4_cidr, halow_ipv4_to_int,
# halow_ipv4_mask_from_prefix, halow_validate_iface_name) and common.sh (logging).

# Address ranges that are always treated as in use, whether or not a route for them is
# present yet: the Supervisor's Docker network (its name and exact range on the target
# device await live validation). Space-separated CIDR list; overridable.
: "${HALOW_RESERVED_CIDRS:=172.30.32.0/23}"

# Upper bound for the number of associated stations, whatever the DHCP pool size.
: "${HALOW_MAX_STATIONS_CAP:=255}"

_halow_uplink_ip() {
    "${HALOW_IP:-ip}" "$@"
}

# _halow_uplink_int_to_ipv4 <int> — prints the dotted quad.
_halow_uplink_int_to_ipv4() {
    local n="$1"
    printf '%d.%d.%d.%d\n' $(( (n >> 24) & 255 )) $(( (n >> 16) & 255 )) $(( (n >> 8) & 255 )) $(( n & 255 ))
}

# halow_uplink_network <cidr> — prints the network form of <cidr> (e.g. 192.168.90.1/24
# -> 192.168.90.0/24). A bare address is treated as /32. 1 if the value is not IPv4.
halow_uplink_network() {
    local cidr="$1" ip prefix ip_i mask
    case "$cidr" in
        */*) ;;
        *) cidr="${cidr}/32" ;;
    esac
    if ! halow_validate_ipv4_cidr "$cidr" 2>/dev/null; then
        return 1
    fi
    ip="${cidr%/*}"; prefix="${cidr#*/}"
    ip_i="$(halow_ipv4_to_int "$ip")"
    mask="$(halow_ipv4_mask_from_prefix "$prefix")"
    printf '%s/%s\n' "$(_halow_uplink_int_to_ipv4 $(( ip_i & mask )))" "$prefix"
}

# _halow_uplink_overlap <cidr_a> <cidr_b> — 0 if the two prefixes overlap in either
# direction (one contains the other, or they are equal).
_halow_uplink_overlap() {
    local a="$1" b="$2" pa pb p a_i b_i mask
    pa="${a#*/}"; pb="${b#*/}"
    p="$pa"
    if [ "$pb" -lt "$p" ]; then p="$pb"; fi
    a_i="$(halow_ipv4_to_int "${a%/*}")"
    b_i="$(halow_ipv4_to_int "${b%/*}")"
    mask="$(halow_ipv4_mask_from_prefix "$p")"
    [ $(( a_i & mask )) -eq $(( b_i & mask )) ]
}

# halow_uplink_detect — prints the default-route interface. 1 if there is no default
# route, if the default routes use more than one interface (ambiguous), or if the
# interface name is not a valid interface name.
halow_uplink_detect() {
    local routes ifaces="" line tok prev count=0 dev
    local -a toks
    if routes="$(_halow_uplink_ip -4 route show default 2>/dev/null)"; then :; else
        halow_log_error "uplink: could not read the default route"
        return 1
    fi
    while IFS= read -r line; do
        prev=""
        read -r -a toks <<< "$line"
        for tok in "${toks[@]}"; do
            if [ "$prev" = "dev" ]; then
                case " $ifaces " in
                    *" $tok "*) ;;
                    *) ifaces="${ifaces:+$ifaces }$tok"; count=$((count + 1)) ;;
                esac
            fi
            prev="$tok"
        done
    done <<< "$routes"
    if [ "$count" -eq 0 ]; then
        halow_log_error "uplink: no default route; the uplink interface cannot be determined"
        return 1
    fi
    if [ "$count" -gt 1 ]; then
        halow_log_error "uplink: default routes through more than one interface ($ifaces); refusing to guess"
        return 1
    fi
    dev="$ifaces"
    if ! halow_validate_iface_name "$dev" 2>/dev/null; then
        halow_log_error "uplink: the default-route interface name is not acceptable"
        return 1
    fi
    printf '%s\n' "$dev"
}

# halow_uplink_changed <started_uplink> — 0 if the default-route interface is now
# different from <started_uplink>, or if there is no usable default route any more;
# 1 if it is unchanged.
halow_uplink_changed() {
    local started="$1" now
    if now="$(halow_uplink_detect 2>/dev/null)"; then :; else
        return 0
    fi
    [ "$now" != "$started" ]
}

# _halow_uplink_in_use_prefixes — prints "<cidr> <description>" per line for every IPv4
# address and route on the host (excluding the add-on's own bridge, whose address is the
# add-on's own subnet) plus the reserved ranges. 1 if the host could not be read.
_halow_uplink_in_use_prefixes() {
    local addrs routes line tok dev prev net own="${HALOW_BRIDGE_NAME:-halow-br0}" r
    local -a toks
    if addrs="$(_halow_uplink_ip -o -4 addr show 2>/dev/null)"; then :; else return 1; fi
    if routes="$(_halow_uplink_ip -4 route show 2>/dev/null)"; then :; else return 1; fi
    # `ip -o -4 addr show`: "2: eth0    inet 192.168.1.10/24 brd ... scope global eth0"
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        dev=""; net=""; prev=""
        read -r -a toks <<< "$line"
        for tok in "${toks[@]}"; do
            if [ -z "$dev" ] && [ -n "$prev" ] && [ -z "${prev%%*:}" ]; then dev="$tok"; fi
            if [ "$prev" = "inet" ]; then net="$tok"; fi
            prev="$tok"
        done
        dev="${dev%%@*}"
        [ -z "$net" ] && continue
        [ "$dev" = "$own" ] && continue
        if net="$(halow_uplink_network "$net")"; then
            printf '%s address on %s\n' "$net" "${dev:-unknown}"
        fi
    done <<< "$addrs"
    # `ip -4 route show`: "[type] <prefix|address> [via ...] dev <if> ..." ; default skipped.
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        case "$line" in [[:space:]]*) continue ;; esac
        net=""; dev=""; prev=""
        read -r -a toks <<< "$line"
        for tok in "${toks[@]}"; do
            if [ -z "$net" ]; then
                case "$tok" in
                    default) net="-"; ;;
                    unicast|unreachable|blackhole|prohibit|throw|local|broadcast|multicast|nat|anycast) ;;
                    *) net="$tok" ;;
                esac
            fi
            if [ "$prev" = "dev" ]; then dev="$tok"; fi
            prev="$tok"
        done
        [ "$net" = "-" ] && continue
        [ -z "$net" ] && continue
        [ "$dev" = "$own" ] && continue
        if net="$(halow_uplink_network "$net")"; then
            printf '%s route via %s\n' "$net" "${dev:-unknown}"
        fi
    done <<< "$routes"
    for r in $HALOW_RESERVED_CIDRS; do
        if net="$(halow_uplink_network "$r")"; then
            printf '%s reserved range\n' "$net"
        fi
    done
}

# halow_subnet_collision <cidr> — 0 if <cidr> overlaps no IPv4 address, route or reserved
# range on the host; 1 on a collision (prints the conflicting prefix and where it was
# found on stdout) or if the value is not a valid IPv4 CIDR or the host cannot be read.
halow_subnet_collision() {
    local cidr="$1" net in_use line other desc
    if net="$(halow_uplink_network "$cidr")"; then :; else
        printf 'invalid subnet %s\n' "$cidr"
        return 1
    fi
    case "$cidr" in */*) ;; *) printf 'invalid subnet %s (no prefix length)\n' "$cidr"; return 1 ;; esac
    if in_use="$(_halow_uplink_in_use_prefixes)"; then :; else
        printf 'host addresses and routes could not be read\n'
        return 1
    fi
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        other="${line%% *}"; desc="${line#* }"
        if _halow_uplink_overlap "$net" "$other"; then
            printf '%s overlaps %s (%s)\n' "$net" "$other" "$desc"
            return 1
        fi
    done <<< "$in_use"
    return 0
}

# halow_dhcp_pool_size <start> <end> — prints the number of addresses in the inclusive
# range. 1 if either address is invalid or the range is reversed.
halow_dhcp_pool_size() {
    local start="$1" end="$2" s e
    if ! halow_validate_ipv4_cidr "${start}/32" 2>/dev/null || ! halow_validate_ipv4_cidr "${end}/32" 2>/dev/null; then
        return 1
    fi
    s="$(halow_ipv4_to_int "$start")"; e="$(halow_ipv4_to_int "$end")"
    if [ "$e" -lt "$s" ]; then
        return 1
    fi
    printf '%s\n' $(( e - s + 1 ))
}

# halow_max_stations <start> <end> — prints min(pool size, HALOW_MAX_STATIONS_CAP), at
# least 1. 1 if the range is invalid.
halow_max_stations() {
    local pool cap="$HALOW_MAX_STATIONS_CAP"
    if pool="$(halow_dhcp_pool_size "$1" "$2")"; then :; else
        return 1
    fi
    if [ "$pool" -gt "$cap" ]; then pool="$cap"; fi
    if [ "$pool" -lt 1 ]; then pool=1; fi
    printf '%s\n' "$pool"
}
