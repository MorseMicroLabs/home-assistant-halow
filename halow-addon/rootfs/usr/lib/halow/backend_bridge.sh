#!/usr/bin/env bash
# halow: the `bridge` networking backend (the contract is in backend.sh).
#
# It serves every station through the private internal bridge (bridge.sh), which the core
# creates before the access point starts:
#   attach bridge <name>   port isolation on the parent when it already is a bridge port
#                          (the access point adds it itself), then the gateway address on
#                          the bridge, then dnsmasq bound to the bridge (dnsmasq.sh), then
#                          the NAT chain (halow_fw_install_nat) LAST; a failure at any step
#                          undoes the earlier ones.
#   station_added          makes sure the station's port is a bridge member with port
#                          isolation on (isolation first when the port is already bridged);
#                          a per-station interface (<parent>.sta<N>) also gets IPv6 off
#                          (ipv6.sh) and is kept away from NetworkManager and re-checked. A
#                          per-station interface of a station that is not served (the
#                          capacity limit) leaves the bridge.
#   station_removed        forgets the station; a per-station port leaves the bridge.
#   teardown               DHCP, the NAT chain, the bridge address; idempotent.
# The bridge itself is created and removed by the core (ownership key `net_bridge`).
#
# Ownership keys: net_bridge_addr (content: "<bridge>\n<cidr>", so a separate process can
# undo it), net_dnsmasq, fw_nat. The per-station IPv6 records (ipv6_<iface>) belong to
# ipv6.sh and are restored by the core's rollback.
#
# When an operation fails, HALOW_BB_FAIL_DETAIL holds a one-line reason suitable for the
# status page (for example the port that another service is already using) and
# HALOW_BB_FAIL_KIND says what failed: "nm" when NetworkManager could not be kept away
# from an interface, "other" for everything else (empty after a success). Both describe
# the last operation only and are mirrored in the contract's HALOW_BACKEND_FAIL_DETAIL
# and HALOW_BACKEND_FAIL_KIND; the first station fault is kept by the station lifecycle
# (HALOW_ST_FAULT_KIND).

HALOW_BB_OWNERSHIP_KEYS="net_bridge_addr net_dnsmasq fw_nat"
HALOW_BB_BRIDGE=""
HALOW_BB_SUBNET=""
HALOW_BB_GATEWAY=""
HALOW_BB_DHCP_START=""
HALOW_BB_DHCP_END=""
HALOW_BB_UPLINK=""
HALOW_BB_PARENT=""
HALOW_BB_MAX_STATIONS=""
HALOW_BB_LEASE_TIME="12h"
HALOW_BB_ATTACHED=""
HALOW_BB_FAIL_DETAIL=""
HALOW_BB_FAIL_KIND=""
declare -gA HALOW_BB_STATION_PORT=()   # station mac -> port it is served on

bridge_backend_ownership_keys() {
    printf '%s' "$HALOW_BB_OWNERSHIP_KEYS"
}

# _halow_bb_fail <detail> [<kind:nm|other>]
_halow_bb_fail() {
    HALOW_BB_FAIL_DETAIL="$1"
    HALOW_BB_FAIL_KIND="${2:-other}"
    # The same, under the contract's backend-neutral names (backend.sh).
    HALOW_BACKEND_FAIL_DETAIL="$HALOW_BB_FAIL_DETAIL"
    HALOW_BACKEND_FAIL_KIND="$HALOW_BB_FAIL_KIND"
    halow_log_error "bridge backend: $1"
}

_halow_bb_fail_reset() {
    HALOW_BB_FAIL_DETAIL=""
    HALOW_BB_FAIL_KIND=""
    HALOW_BACKEND_FAIL_DETAIL=""
    HALOW_BACKEND_FAIL_KIND=""
}

_halow_bb_ip() {
    "${HALOW_IP:-ip}" "$@"
}

# _halow_bb_has_cidr <iface> <cidr> — 0 if the host shows <cidr> on <iface>.
_halow_bb_has_cidr() {
    local iface="$1" cidr="$2" out
    out="$(_halow_bb_ip -4 addr show dev "$iface" 2>/dev/null || true)"
    grep -q -F -- " ${cidr} " <<< "$out "
}

# bridge_backend_configure bridge=<name> subnet=<gateway-cidr> dhcp_start=<ip> dhcp_end=<ip>
#                          uplink=<iface> parent=<iface> max_stations=<n> [lease_time=<t>]
# Every key except lease_time is required; unknown or repeated keys are refused. The
# subnet is given in gateway form (e.g. 192.168.90.1/24): its address part is the gateway.
bridge_backend_configure() {
    local kv key value seen=" "
    local bridge="" subnet="" dstart="" dend="" uplink="" parent="" maxst="" lease="12h"
    _halow_bb_fail_reset
    if [ -n "$HALOW_BB_ATTACHED" ]; then
        _halow_bb_fail "configure refused: the backend is attached to $HALOW_BB_ATTACHED"
        return 1
    fi
    for kv in "$@"; do
        case "$kv" in
            *=*) key="${kv%%=*}"; value="${kv#*=}" ;;
            *) _halow_bb_fail "configure: '$kv' is not key=value"; return 1 ;;
        esac
        case "$seen" in *" $key "*) _halow_bb_fail "configure: '$key' given more than once"; return 1 ;; esac
        seen="${seen}${key} "
        case "$key" in
            bridge) bridge="$value" ;;
            subnet) subnet="$value" ;;
            dhcp_start) dstart="$value" ;;
            dhcp_end) dend="$value" ;;
            uplink) uplink="$value" ;;
            parent) parent="$value" ;;
            max_stations) maxst="$value" ;;
            lease_time) lease="$value" ;;
            *) _halow_bb_fail "configure: unknown key '$key'"; return 1 ;;
        esac
    done
    for key in bridge subnet dhcp_start dhcp_end uplink parent max_stations; do
        case "$seen" in *" $key "*) ;; *) _halow_bb_fail "configure: '$key' is required"; return 1 ;; esac
    done
    if [ -z "$bridge" ] || [ -z "$subnet" ] || [ -z "$dstart" ] || [ -z "$dend" ] || [ -z "$uplink" ] || [ -z "$parent" ] || [ -z "$maxst" ]; then
        _halow_bb_fail "configure: every value must be non-empty"
        return 1
    fi
    halow_validate_iface_name "$bridge" || { _halow_bb_fail "configure: invalid bridge name '$bridge'"; return 1; }
    halow_validate_iface_name "$uplink" || { _halow_bb_fail "configure: invalid uplink interface '$uplink'"; return 1; }
    halow_validate_iface_name "$parent" || { _halow_bb_fail "configure: invalid parent interface '$parent'"; return 1; }
    if [ "$bridge" = "$uplink" ] || [ "$bridge" = "$parent" ] || [ "$parent" = "$uplink" ]; then
        _halow_bb_fail "configure: bridge, parent and uplink must be three different interfaces"
        return 1
    fi
    halow_validate_ipv4_cidr "$subnet" || { _halow_bb_fail "configure: invalid subnet '$subnet'"; return 1; }
    halow_validate_dhcp_range "$dstart" "$dend" "$subnet" || { _halow_bb_fail "configure: invalid DHCP range $dstart-$dend for $subnet"; return 1; }
    if ! [[ "$maxst" =~ ^[0-9]+$ ]] || [ "$maxst" -lt 1 ] || [ "$maxst" -gt 255 ]; then
        _halow_bb_fail "configure: max_stations must be 1-255 (got '$maxst')"
        return 1
    fi
    if [ "$lease" != "infinite" ] && ! [[ "$lease" =~ ^[0-9]+[smhd]?$ ]]; then
        _halow_bb_fail "configure: invalid lease_time '$lease'"
        return 1
    fi
    HALOW_BB_BRIDGE="$bridge"
    HALOW_BB_SUBNET="$subnet"
    HALOW_BB_GATEWAY="${subnet%/*}"
    HALOW_BB_DHCP_START="$dstart"
    HALOW_BB_DHCP_END="$dend"
    HALOW_BB_UPLINK="$uplink"
    HALOW_BB_PARENT="$parent"
    HALOW_BB_MAX_STATIONS="$maxst"
    HALOW_BB_LEASE_TIME="$lease"
    HALOW_BB_STATION_PORT=()
    return 0
}

# _halow_bb_remove_address — undo net_bridge_addr from its own marker content. 0 when
# nothing of ours remains (marker cleared), 1 when the address is still present.
_halow_bb_remove_address() {
    local marker bridge cidr
    halow_own_check "net_bridge_addr" || return 0
    marker="$(halow_own_get "net_bridge_addr")"
    bridge="${marker%%$'\n'*}"
    cidr="${marker#*$'\n'}"
    if ! halow_validate_iface_name "$bridge" || ! halow_validate_ipv4_cidr "$cidr"; then
        halow_log_error "bridge backend: the net_bridge_addr record is malformed; ownership kept for manual review"
        return 1
    fi
    if ! halow_kernel_iface_exists "$bridge"; then
        halow_own_clear "net_bridge_addr"
        halow_log_info "bridge backend: $bridge no longer exists; its address went with it"
        return 0
    fi
    if _halow_bb_has_cidr "$bridge" "$cidr"; then
        _halow_bb_ip addr del "$cidr" dev "$bridge" 2>/dev/null || true
    fi
    if _halow_bb_has_cidr "$bridge" "$cidr"; then
        halow_log_error "bridge backend: could not remove $cidr from $bridge; ownership kept"
        return 1
    fi
    halow_own_clear "net_bridge_addr"
    halow_log_info "bridge backend: removed $cidr from $bridge"
    return 0
}

# _halow_bb_remove_nat — 0 when the NAT chain is confirmed gone (fw_nat cleared).
_halow_bb_remove_nat() {
    if ! declare -F halow_fw_remove_nat >/dev/null 2>&1; then
        halow_log_error "bridge backend: the firewall library is not loaded; the NAT chain cannot be removed from here"
        return 1
    fi
    if halow_fw_remove_nat; then
        halow_own_clear "fw_nat"
        return 0
    fi
    halow_log_error "bridge backend: the NAT chain could not be confirmed removed; ownership kept"
    return 1
}

# bridge_backend_attach <kind> <attachment>
bridge_backend_attach() {
    local kind="${1:-}" name="${2:-}" conflict crc
    _halow_bb_fail_reset
    if [ "$kind" != "bridge" ]; then
        halow_log_error "bridge backend: attachment kind '$kind' is not supported (only 'bridge')"
        return "$HALOW_BACKEND_RC_UNSUPPORTED"
    fi
    if [ -n "$HALOW_BB_ATTACHED" ]; then
        halow_log_warning "bridge backend: already attached to $HALOW_BB_ATTACHED; it serves one bridge, so $name is not served"
        return "$HALOW_BACKEND_RC_LIMIT"
    fi
    if [ -z "$HALOW_BB_BRIDGE" ]; then
        _halow_bb_fail "attach before configure"
        return 1
    fi
    if [ "$name" != "$HALOW_BB_BRIDGE" ]; then
        _halow_bb_fail "attach to '$name' but the configured bridge is '$HALOW_BB_BRIDGE'"
        return 1
    fi
    if ! halow_bridge_exists "$name"; then
        _halow_bb_fail "the bridge $name does not exist"
        return 1
    fi

    # 0. The access point adds its parent interface to the bridge itself: isolate it now,
    #    before the bridge gets an address or DHCP, rather than at the first station.
    local pmaster
    pmaster="$(halow_bridge_port_master "$HALOW_BB_PARENT")"
    if [ "$pmaster" = "$name" ]; then
        if ! halow_bridge_port_isolate "$HALOW_BB_PARENT" on; then
            _halow_bb_fail "port isolation could not be set on $HALOW_BB_PARENT"
            return 1
        fi
    elif [ -n "$pmaster" ]; then
        _halow_bb_fail "$HALOW_BB_PARENT is a port of $pmaster, not of $name"
        return 1
    fi

    # 1. gateway address on the bridge (marker first).
    if _halow_bb_has_cidr "$name" "$HALOW_BB_SUBNET"; then
        if halow_own_check "net_bridge_addr"; then
            halow_log_info "bridge backend: $name already has $HALOW_BB_SUBNET (this add-on's)"
        else
            halow_log_warning "bridge backend: $name already has $HALOW_BB_SUBNET without a record of adding it; it goes when the bridge is removed"
        fi
    else
        if ! halow_own_mark "net_bridge_addr" "$(printf '%s\n%s' "$name" "$HALOW_BB_SUBNET")"; then
            _halow_bb_fail "could not record ownership of the bridge address"
            return 1
        fi
        if ! _halow_bb_ip addr add "$HALOW_BB_SUBNET" dev "$name"; then
            _halow_bb_fail "could not add $HALOW_BB_SUBNET to $name"
            _halow_bb_remove_address || true
            return 1
        fi
    fi
    if ! _halow_bb_ip link set dev "$name" up; then
        _halow_bb_fail "could not bring $name up"
        _halow_bb_remove_address || true
        return 1
    fi

    # 2. DHCP/DNS bound to the bridge, after making sure nothing else holds its ports.
    halow_dnsmasq_outcome_run
    if [ "$HALOW_DNSMASQ_OUTCOME" = "confirmed_absent" ]; then
        if conflict="$(halow_dnsmasq_port_conflict_check "$HALOW_BB_GATEWAY")"; then crc=0; else crc=$?; fi
        if [ "$crc" -eq 1 ]; then
            _halow_bb_fail "DHCP/DNS cannot start: ${conflict%%$'\n'*}"
            _halow_bb_remove_address || true
            return 1
        elif [ "$crc" -ne 0 ]; then
            halow_log_warning "bridge backend: port check skipped: $conflict"
        fi
    fi
    if ! halow_dnsmasq_start "$name" "$HALOW_BB_GATEWAY" "$HALOW_BB_DHCP_START" "$HALOW_BB_DHCP_END" "$HALOW_BB_LEASE_TIME"; then
        _halow_bb_fail "DHCP/DNS (dnsmasq) could not be started on $name"
        halow_dnsmasq_stop || true
        _halow_bb_remove_address || true
        return 1
    fi

    # 3. NAT chain, last.
    if ! declare -F halow_fw_install_nat >/dev/null 2>&1; then
        _halow_bb_fail "the firewall library is not loaded; NAT cannot be installed"
        halow_dnsmasq_stop || true
        _halow_bb_remove_address || true
        return 1
    fi
    # halow_fw_install_nat writes the fw_nat marker itself before changing anything.
    if ! halow_fw_install_nat "$name" "$HALOW_BB_SUBNET" "$HALOW_BB_UPLINK"; then
        _halow_bb_fail "the NAT chain could not be installed for $HALOW_BB_SUBNET via $HALOW_BB_UPLINK"
        _halow_bb_remove_nat || true
        halow_dnsmasq_stop || true
        _halow_bb_remove_address || true
        return 1
    fi
    HALOW_BB_ATTACHED="$name"
    HALOW_BB_STATION_PORT=()
    halow_log_info "bridge backend: attached to $name ($HALOW_BB_SUBNET, DHCP $HALOW_BB_DHCP_START-$HALOW_BB_DHCP_END, NAT via $HALOW_BB_UPLINK)"
    return 0
}

# _halow_bb_is_station_iface <port> — 0 if <port> is named <parent>.sta<N>.
_halow_bb_is_station_iface() {
    local port="$1" rest
    rest="${port#"${HALOW_BB_PARENT}".sta}"
    [ "$rest" != "$port" ] && [[ "$rest" =~ ^[0-9]+$ ]]
}

# _halow_bb_nm_probe <iface> — ONE immediate, silent NetworkManager query for <iface>.
# 0: NetworkManager positively answered UnknownDevice (it has no Device for it);
# 1: NetworkManager lists a Device; 2: no definite answer (bus unreachable, permission
# denied, NetworkManager not running, anything unexpected). Never logs: the caller decides.
_halow_bb_nm_probe() {
    local iface="$1" reply path
    reply="$(dbus-send --system --print-reply --dest=org.freedesktop.NetworkManager \
        /org/freedesktop/NetworkManager \
        org.freedesktop.NetworkManager.GetDeviceByIpIface "string:${iface}" 2>&1 || true)"
    path="$(printf '%s\n' "$reply" | awk '/^[[:space:]]*object path "\// {print $3}' | tr -d '"')"
    if [ -n "$path" ]; then
        return 1
    fi
    case "$reply" in
        *"org.freedesktop.NetworkManager.UnknownDevice"*) return 0 ;;
    esac
    return 2
}

# bridge_backend_station_added <port> <mac>
# 0 served; 10 more stations than max_stations; 1 hard failure.
bridge_backend_station_added() {
    local port="${1:-}" mac="${2:-}" count=0 wds=0 key="" v6rc=0
    _halow_bb_fail_reset
    mac="${mac,,}"
    if [ -z "$HALOW_BB_ATTACHED" ]; then
        _halow_bb_fail "station $mac reported on $port but the backend is not attached"
        return 1
    fi
    if ! [[ "$mac" =~ ^[0-9a-f]{2}(:[0-9a-f]{2}){5}$ ]]; then
        _halow_bb_fail "station id '$mac' is not a MAC address"
        return 1
    fi
    halow_validate_iface_name "$port" || { _halow_bb_fail "invalid port name for station $mac"; return 1; }
    if [ "$port" = "$HALOW_BB_PARENT" ]; then
        wds=0
    elif _halow_bb_is_station_iface "$port"; then
        wds=1
    else
        _halow_bb_fail "station $mac reported on $port, which is neither $HALOW_BB_PARENT nor one of its per-station interfaces"
        return 1
    fi
    if ! halow_kernel_iface_exists "$port"; then
        _halow_bb_fail "station $mac: port $port does not exist"
        return 1
    fi
    # The access point may already have made the port a bridge member: isolate it before
    # anything else, so it never forwards to other ports while the rest is checked.
    if [ "$(halow_bridge_port_master "$port")" = "$HALOW_BB_ATTACHED" ]; then
        if ! halow_bridge_port_isolate "$port" on; then
            _halow_bb_fail "station $mac: port isolation could not be set on $port"
            if [ "$wds" -eq 1 ]; then halow_bridge_port_remove "$port" || true; fi
            return 1
        fi
    fi
    if [ -z "${HALOW_BB_STATION_PORT[$mac]:-}" ]; then
        count="${#HALOW_BB_STATION_PORT[@]}"
        if [ "$count" -ge "$HALOW_BB_MAX_STATIONS" ]; then
            halow_log_warning "bridge backend: station $mac not served: $count stations already served (limit $HALOW_BB_MAX_STATIONS)"
            if [ "$wds" -eq 1 ] && ! halow_bridge_port_remove "$port"; then
                # A station that is not served must not keep a bridged port.
                _halow_bb_fail "station $mac is over the station limit and its port $port could not be released from the bridge"
                return 1
            fi
            return "$HALOW_BACKEND_RC_LIMIT"
        fi
    fi
    if [ "$wds" -eq 1 ]; then
        key="nm_unmanaged_wds_${port}"
        # NetworkManager normally never lists a per-station interface (it cannot manage what
        # it does not see), so ask ONCE, immediately, without a wait. Only a definite
        # UnknownDevice is accepted here, quietly (one INFO line); a Device that IS listed
        # and any query that cannot be answered take the unchanged path below (the full wait,
        # mark unmanaged, fail closed). A Device that appears after this query is caught by
        # the post-check further down.
        if _halow_bb_nm_probe "$port"; then
            halow_log_info "bridge backend: NetworkManager has no Device for per-station interface $port (expected: it does not manage an interface it does not list); no ownership record is needed, re-checked once $port is set up"
        elif ! halow_nm_mark_unmanaged_if_known "$port" "$key"; then
            _halow_bb_fail "station $mac: could not keep NetworkManager away from $port" nm
            return 1
        fi
    fi
    if ! halow_bridge_port_add "$HALOW_BB_ATTACHED" "$port"; then
        _halow_bb_fail "station $mac: $port could not be made a port of $HALOW_BB_ATTACHED"
        return 1
    fi
    if ! halow_bridge_port_isolate "$port" on; then
        _halow_bb_fail "station $mac: port isolation could not be set on $port"
        # Fail closed: a per-station port without isolation does not stay in the bridge.
        if [ "$wds" -eq 1 ]; then halow_bridge_port_remove "$port" || true; fi
        return 1
    fi
    if [ "$wds" -eq 1 ]; then
        # IPv6 off on the per-station interface (the first IPv6 layer). When that cannot
        # be verified the station is still served only if the IPv6 chains are verified.
        v6rc=0
        halow_ipv6_disable "$port" || v6rc=$?
        if [ "$v6rc" -eq 2 ]; then
            # A temporary writable mount on the switch is not confirmed removed: never the
            # firewall-only fallback.
            _halow_bb_fail "station $mac: IPv6 could not be turned off on $port and a temporary writable mount on its switch could not be confirmed removed"
            halow_bridge_port_remove "$port" || true
            return 1
        elif [ "$v6rc" -ne 0 ]; then
            if declare -F halow_fw_ipv6_governed >/dev/null 2>&1 && halow_fw_ipv6_governed "$HALOW_BB_ATTACHED"; then
                halow_log_warning "bridge backend: IPv6 could not be turned off on $port; the IPv6 firewall chains still drop it (IPv6 is held by the filter chains only)"
            else
                _halow_bb_fail "station $mac: IPv6 could not be turned off on $port and the IPv6 firewall chains are not verified"
                halow_bridge_port_remove "$port" || true
                return 1
            fi
        fi
    fi
    if [ "$wds" -eq 1 ] && ! halow_own_check "$key"; then
        if ! halow_nm_assert_no_device "$port"; then
            _halow_bb_fail "station $mac: NetworkManager started tracking $port" nm
            return 1
        fi
    fi
    if ! _halow_bb_has_cidr "$HALOW_BB_ATTACHED" "$HALOW_BB_SUBNET"; then
        _halow_bb_fail "station $mac: $HALOW_BB_ATTACHED no longer has $HALOW_BB_SUBNET"
        return 1
    fi
    HALOW_BB_STATION_PORT["$mac"]="$port"
    halow_log_info "bridge backend: station $mac served on $port"
    return 0
}

# bridge_backend_station_removed <port> <mac>
# Forget the station; a per-station port leaves the bridge (the parent stays). 1 on failure.
bridge_backend_station_removed() {
    local port="${1:-}" mac="${2:-}"
    mac="${mac,,}"
    _halow_bb_fail_reset
    if [ -n "$mac" ] && [ -n "${HALOW_BB_STATION_PORT[$mac]:-}" ] && [ "${HALOW_BB_STATION_PORT[$mac]}" = "$port" ]; then
        unset 'HALOW_BB_STATION_PORT[$mac]'
    fi
    if [ -n "$port" ] && [ "$port" != "$HALOW_BB_PARENT" ]; then
        halow_validate_iface_name "$port" || { _halow_bb_fail "invalid port name '$port'"; return 1; }
        if ! halow_bridge_port_remove "$port"; then
            _halow_bb_fail "station $mac: $port could not be released from the bridge"
            return 1
        fi
        # A per-station interface that is gone took its IPv6 setting with it: drop its
        # record (one that still exists keeps IPv6 off until the rollback restores it).
        halow_ipv6_forget_if_gone "$port" || true
    fi
    return 0
}

# bridge_backend_teardown
# DHCP, then the NAT chain, then the bridge address. Reads only durable state (markers and
# the host). Returns 1 for a hard failure that no ownership key can represent: a live
# dnsmasq matching this add-on's identity without a marker, or a NAT chain that could not
# be confirmed removed although no marker is held. Kept markers report everything else.
bridge_backend_teardown() {
    local hard=0
    if ! halow_dnsmasq_stop; then hard=1; fi
    if ! _halow_bb_remove_nat; then
        halow_own_check "fw_nat" || hard=1
    fi
    _halow_bb_remove_address || true
    HALOW_BB_ATTACHED=""
    HALOW_BB_STATION_PORT=()
    return "$hard"
}

# bridge_backend_health — dnsmasq running, the bridge present with its address.
bridge_backend_health() {
    [ -n "$HALOW_BB_ATTACHED" ] || return 1
    halow_dnsmasq_running || return 1
    halow_bridge_exists "$HALOW_BB_ATTACHED" || return 1
    _halow_bb_has_cidr "$HALOW_BB_ATTACHED" "$HALOW_BB_SUBNET" || return 1
    return 0
}
