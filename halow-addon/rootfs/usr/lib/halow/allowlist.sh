#!/usr/bin/env bash
# halow: the customer allow-list of host and published-add-on ports that HaLow clients
# may reach on the gateway address.
#
# One validated list feeds two firewall rules per entry: a host-direct rule (a service
# listening on the host network, for example an MQTT broker add-on with host networking or
# Home Assistant itself on 8123) and a forwarded rule for a Docker-published add-on port
# reached through the gateway address. The default is an empty list: HaLow clients reach
# only DHCP, DNS and ICMP echo on the gateway.
#
# Entry format: "tcp/<port>" or "udp/<port>", lower case, decimal port 1-65535 without
# leading zeros. Entries may be given as separate arguments or separated by whitespace or
# commas inside one argument. Defines functions and constants only.

# Maximum number of entries (each entry becomes two rules).
: "${HALOW_ALLOWLIST_MAX:=32}"

# Denied ports, as "<proto|any>|<first>|<last>|<reason>" lines. This list is deliberately
# short: it refuses the host-management and Supervisor ports that the app must never
# expose. It is not a list of every service on the host, and a list of port numbers cannot
# be complete for an arbitrary system. Every other port is unreachable from the Wi-Fi HaLow
# network by default and becomes reachable only when the customer lists it; the
# documentation warns about that. Ports a customer may legitimately expose (for example
# 8123 for Home Assistant itself, 1883/8883 for an MQTT broker, 80/443 for a reverse-proxy
# add-on) are not denied.
#   22          SSH: host and SSH-add-on management access.
#   22222       the host operating system's developer SSH access.
#   4357        the Supervisor's observer plug-in (reports Supervisor health).
#   62000-65500 the Supervisor's Ingress port range: Ingress services trust the
#               Supervisor's proxy and must only be reached through it.
HALOW_ALLOWLIST_DENY="any|22|22|SSH is reserved for host management
any|22222|22222|the host's developer SSH port is reserved for host management
any|4357|4357|the Supervisor observer port is reserved for the Supervisor
any|62000|65500|the Ingress port range is reserved for the Supervisor's Ingress proxy"

# halow_allowlist_entries <entry…> — prints each entry on its own line (splitting on
# whitespace and commas), without validating. Empty input prints nothing.
halow_allowlist_entries() {
    local arg e
    local -a parts
    for arg in "$@"; do
        arg="${arg//,/ }"
        read -r -a parts <<< "$arg"
        for e in "${parts[@]}"; do
            [ -n "$e" ] && printf '%s\n' "$e"
        done
    done
    return 0
}

# _halow_allowlist_denied <proto> <port> — prints the reason and returns 0 if denied.
_halow_allowlist_denied() {
    local proto="$1" port="$2" line dproto first last reason rest
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        dproto="${line%%|*}"; rest="${line#*|}"
        first="${rest%%|*}"; rest="${rest#*|}"
        last="${rest%%|*}"; reason="${rest#*|}"
        if [ "$dproto" != "any" ] && [ "$dproto" != "$proto" ]; then continue; fi
        if [ "$port" -ge "$first" ] && [ "$port" -le "$last" ]; then
            printf '%s\n' "$reason"
            return 0
        fi
    done <<< "$HALOW_ALLOWLIST_DENY"
    return 1
}

# halow_allowlist_validate <entry…> — 0 if every entry is valid (an empty list is
# valid); 1 otherwise, printing one line "<entry>: <reason>" on stdout for the first
# offending entry.
halow_allowlist_validate() {
    local entries e proto port seen=" " count=0 reason
    entries="$(halow_allowlist_entries "$@")"
    while IFS= read -r e; do
        [ -z "$e" ] && continue
        count=$((count + 1))
        if [ "$count" -gt "$HALOW_ALLOWLIST_MAX" ]; then
            printf '%s: more than %s entries\n' "$e" "$HALOW_ALLOWLIST_MAX"
            return 1
        fi
        case "$e" in
            tcp/*|udp/*) proto="${e%%/*}"; port="${e#*/}" ;;
            *) printf '%s: not of the form tcp/<port> or udp/<port>\n' "$e"; return 1 ;;
        esac
        case "$port" in
            ''|*[!0-9]*) printf '%s: the port is not a decimal number\n' "$e"; return 1 ;;
            0*) printf '%s: the port must be 1-65535 without leading zeros\n' "$e"; return 1 ;;
        esac
        if [ "${#port}" -gt 5 ] || [ "$port" -gt 65535 ]; then
            printf '%s: the port must be 1-65535\n' "$e"
            return 1
        fi
        if reason="$(_halow_allowlist_denied "$proto" "$port")"; then
            printf '%s: %s\n' "$e" "$reason"
            return 1
        fi
        case "$seen" in
            *" $e "*) printf '%s: duplicate entry\n' "$e"; return 1 ;;
        esac
        seen="${seen}${e} "
    done <<< "$entries"
    return 0
}
