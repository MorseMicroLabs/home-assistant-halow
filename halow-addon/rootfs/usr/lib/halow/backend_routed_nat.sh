#!/usr/bin/env bash
# halow: the routed/NAT backend, expressed through the core/backend contract (backend.sh).
#
# This file is only an ADAPTER. Every mutation (address, ip_forward, NAT/FORWARD rules,
# dnsmasq) still lives, unchanged in behaviour, in network_backend.sh; this file maps the
# contract's operations onto it and nothing more. Nothing in the core calls
# network_backend.sh directly any more.
#
# Current limits (carried over deliberately, not new):
#   - It attaches to exactly ONE attachment of kind `station-interface` (the first
#     station's own interface). A second attachment, or a station reported on any other
#     attachment, is refused with return code 10 ("limit") so the core can log it and
#     carry on; it never fails the whole run.
#   - Attachment kind `bridge` is refused with return code 2: the private-bridge model is
#     defined by the contract but not implemented here.
#   - When a station leaves, nothing is torn down: the address, rules and DHCP service stay
#     in place until the whole backend is torn down on stop.

HALOW_RN_SUBNET_CIDR=""
HALOW_RN_DHCP_START=""
HALOW_RN_DHCP_END=""
HALOW_RN_UPLINK=""
HALOW_RN_ATTACHMENT=""

# routed_nat_backend_ownership_keys
routed_nat_backend_ownership_keys() {
    printf '%s' "$HALOW_NET_OWNERSHIP_KEYS"
}

# routed_nat_backend_configure subnet=<cidr> dhcp_start=<ip> dhcp_end=<ip> [uplink=<iface>]
# Validates every value with the same validators the startup sequence has always used,
# and — when no uplink is given — derives it from the default route. Runs before any host
# mutation, so an invalid value stops the run before anything has been changed.
routed_nat_backend_configure() {
    local kv explicit_uplink=""
    HALOW_RN_SUBNET_CIDR="" HALOW_RN_DHCP_START="" HALOW_RN_DHCP_END="" HALOW_RN_UPLINK=""
    for kv in "$@"; do
        case "$kv" in
            subnet=*) HALOW_RN_SUBNET_CIDR="${kv#subnet=}" ;;
            dhcp_start=*) HALOW_RN_DHCP_START="${kv#dhcp_start=}" ;;
            dhcp_end=*) HALOW_RN_DHCP_END="${kv#dhcp_end=}" ;;
            uplink=*) explicit_uplink="${kv#uplink=}" ;;
            *) ;;
        esac
    done
    if [ -z "$HALOW_RN_SUBNET_CIDR" ] || [ -z "$HALOW_RN_DHCP_START" ] || [ -z "$HALOW_RN_DHCP_END" ]; then
        halow_log_error "routed/NAT backend: subnet, dhcp_start and dhcp_end are all required"
        return 1
    fi
    if ! halow_validate_ipv4_cidr "$HALOW_RN_SUBNET_CIDR"; then
        halow_log_error "routed/NAT backend: halow_subnet_cidr '$HALOW_RN_SUBNET_CIDR' is not a valid IPv4 CIDR"
        return 1
    fi
    if ! halow_validate_dhcp_range "$HALOW_RN_DHCP_START" "$HALOW_RN_DHCP_END" "$HALOW_RN_SUBNET_CIDR"; then
        halow_log_error "routed/NAT backend: dhcp_range_start/dhcp_range_end failed validation"
        return 1
    fi
    if [ -n "$explicit_uplink" ]; then
        if ! halow_validate_iface_name "$explicit_uplink"; then
            halow_log_error "routed/NAT backend: uplink_interface '$explicit_uplink' is not a valid interface name"
            return 1
        fi
        HALOW_RN_UPLINK="$explicit_uplink"
        halow_log_info "routed/NAT backend: uplink interface set explicitly to $HALOW_RN_UPLINK"
    else
        if ! HALOW_RN_UPLINK="$(halow_default_uplink_iface)"; then
            HALOW_RN_UPLINK=""
            halow_log_error "routed/NAT backend: could not derive the default-route (uplink) interface automatically; set uplink_interface explicitly"
            return 1
        fi
        halow_log_info "routed/NAT backend: uplink interface auto-detected as $HALOW_RN_UPLINK"
    fi
    return 0
}

# routed_nat_backend_attach <kind> <attachment>
routed_nat_backend_attach() {
    local kind="${1:-}" attachment="${2:-}"
    case "$kind" in
        station-interface) ;;
        *)
            halow_log_error "routed/NAT backend: attachment kind '$kind' is not supported"
            return "$HALOW_BACKEND_RC_UNSUPPORTED"
            ;;
    esac
    if [ -n "$HALOW_RN_ATTACHMENT" ]; then
        halow_log_warning "routed/NAT backend: already attached to $HALOW_RN_ATTACHMENT; it serves one attachment, so $attachment is not served"
        return "$HALOW_BACKEND_RC_LIMIT"
    fi
    if [ -z "$attachment" ]; then
        halow_log_error "routed/NAT backend: no attachment name given"
        return 1
    fi
    if halow_apply_network "$attachment" "$HALOW_RN_SUBNET_CIDR" "$HALOW_RN_DHCP_START" "$HALOW_RN_DHCP_END" "$HALOW_RN_UPLINK"; then
        HALOW_RN_ATTACHMENT="$attachment"
        return 0
    fi
    return 1
}

# routed_nat_backend_station_added <port> <station-id>
# 0 only when the station really is served; 10 when it is on an interface this backend does not
# serve (an expected limit); 1 (hard error) when the attachment has lost its address.
routed_nat_backend_station_added() {
    local attachment="${1:-}" station="${2:-}"
    if [ -n "$HALOW_RN_ATTACHMENT" ] && [ "$attachment" = "$HALOW_RN_ATTACHMENT" ]; then
        # A station interface that vanished and was re-created has lost the address this
        # backend gave it. This build does not re-apply it (the private-bridge model removes
        # the dependence on a transient interface); say so rather than pretend.
        if ! halow_iface_has_cidr "$attachment" "$HALOW_RN_SUBNET_CIDR"; then
            halow_log_error "routed/NAT backend: $attachment no longer has $HALOW_RN_SUBNET_CIDR (a re-created station interface is not re-addressed in this build); station $station has no service"
            return 1
        else
            halow_log_info "routed/NAT backend: station $station is served through $attachment"
        fi
        return 0
    fi
    if [ -z "$HALOW_RN_ATTACHMENT" ]; then
        halow_log_error "routed/NAT backend: station $station reported on $attachment but this backend has no attachment"
        return 1
    fi
    halow_log_warning "routed/NAT backend: station $station is on $attachment, which this backend does not serve (it serves $HALOW_RN_ATTACHMENT)"
    return "$HALOW_BACKEND_RC_LIMIT"
}

# routed_nat_backend_station_removed <attachment> <station-id>
routed_nat_backend_station_removed() {
    local attachment="${1:-}" station="${2:-}"
    halow_log_info "routed/NAT backend: station $station left $attachment (service stays in place until teardown)"
    return 0
}

# routed_nat_backend_teardown
# Exactly the two steps rollback used to run inline, in the same order and with the same
# meaning of the return code:
#   1. dnsmasq's own identity scan/stop, ALWAYS (it needs no persisted values); its
#      return value is the hard-failure signal.
#   2. the rest of the network state, only when the persisted values can be loaded; its
#      own residue is reported through the ownership keys, not through this return code.
routed_nat_backend_teardown() {
    local hard_failure=0
    halow_teardown_dnsmasq || hard_failure=1
    if halow_load_network_values; then
        halow_teardown_network "$HALOW_NET_IFACE" "$HALOW_NET_UPLINK" "$HALOW_NET_CIDR"
    else
        halow_log_info "rollback: no persisted (or no validly-parsed) network state found; nothing further to tear down there (dnsmasq's own teardown above runs regardless)"
    fi
    HALOW_RN_ATTACHMENT=""
    return "$hard_failure"
}

# routed_nat_backend_health — healthy while dnsmasq positively matches this package's
# own identity.
routed_nat_backend_health() {
    if halow_dnsmasq_is_running "${HALOW_STATE_DIR:?}/dnsmasq.pid"; then
        return 0
    fi
    return 1
}
