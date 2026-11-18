#!/usr/bin/env bash
# halow: the private internal bridge.
#
# The access point's parent interface and every per-station interface are ports of one
# bridge that this add-on creates, owns and removes. The bridge has no LAN member: the
# gateway address, DHCP and the firewall chains attach to it, and upstream traffic is
# routed and NATed exactly as before. Station arrival and departure only change bridge
# membership, so nothing depends on a transient per-station interface.
#
# Rules this file keeps:
#   - the ownership marker `net_bridge` (content: the bridge name) is written BEFORE the
#     bridge is created and cleared only after its absence is confirmed from the host;
#   - the bridge MAC is pinned to a deterministic locally administered unicast address
#     derived from the bridge name (otherwise it follows the lowest port MAC and changes
#     as stations come and go, which makes clients' ARP entries flap);
#   - STP is off (a private bridge with no loops; STP would also delay forwarding on every
#     new port);
#   - every state check reads the host (HALOW_SYS_CLASS_NET_DIR), never only the marker.
#
# External commands: `ip` (HALOW_IP) and `bridge` (HALOW_BRIDGE_CMD), both overridable.

# _halow_bridge_sys — the sysfs network directory (redirectable for tests).
_halow_bridge_sys() {
    printf '%s' "${HALOW_SYS_CLASS_NET_DIR:-/sys/class/net}"
}

_halow_bridge_ip() {
    "${HALOW_IP:-ip}" "$@"
}

_halow_bridge_cmd() {
    "${HALOW_BRIDGE_CMD:-bridge}" "$@"
}

# halow_bridge_mac <name>
# Print the pinned MAC for <name>: 02 (locally administered, unicast) followed by five
# bytes of the SHA-256 of the name. Deterministic, so a restart pins the same address.
halow_bridge_mac() {
    local name="$1" sum hex
    if ! sum="$(printf 'halow-bridge:%s' "$name" | sha256sum)"; then
        halow_log_error "bridge: could not derive a MAC address for $name"
        return 1
    fi
    hex="${sum%% *}"
    if ! [[ "$hex" =~ ^[0-9a-f]{10} ]]; then
        halow_log_error "bridge: unexpected checksum output while deriving a MAC address for $name"
        return 1
    fi
    printf '02:%s:%s:%s:%s:%s' "${hex:0:2}" "${hex:2:2}" "${hex:4:2}" "${hex:6:2}" "${hex:8:2}"
}

# halow_bridge_exists <name> — 0 if an interface of that name exists on the host.
halow_bridge_exists() {
    local name="${1:-}"
    [ -n "$name" ] || return 1
    [ -d "$(_halow_bridge_sys)/$name" ]
}

# halow_bridge_is_bridge <name> — 0 if <name> exists and is a bridge device.
halow_bridge_is_bridge() {
    local name="${1:-}"
    [ -n "$name" ] || return 1
    [ -d "$(_halow_bridge_sys)/$name/bridge" ]
}

# halow_bridge_port_master <iface> — print the bridge <iface> is a port of (empty if none).
halow_bridge_port_master() {
    local iface="$1" link
    link="$(readlink -- "$(_halow_bridge_sys)/$iface/master" 2>/dev/null || true)"
    printf '%s' "${link##*/}"
}

# halow_bridge_ports <bridge> — print the bridge's ports, one per line.
halow_bridge_ports() {
    local bridge="$1" dir p
    dir="$(_halow_bridge_sys)/$bridge/brif"
    [ -d "$dir" ] || return 0
    for p in "$dir"/*; do
        if [ -e "$p" ] || [ -L "$p" ]; then
            printf '%s\n' "${p##*/}"
        fi
    done
}

# _halow_bridge_read <file> — print the first line of a sysfs attribute (empty if absent).
_halow_bridge_read() {
    local file="$1" value=""
    if [ -r "$file" ]; then
        IFS= read -r value < "$file" || true
    fi
    printf '%s' "$value"
}

# _halow_bridge_settle <name>
# Pin the MAC, turn STP off and bring the bridge up, then confirm each from the host.
_halow_bridge_settle() {
    local name="$1" mac sys actual stp
    sys="$(_halow_bridge_sys)"
    mac="$(halow_bridge_mac "$name")" || return 1
    if ! _halow_bridge_ip link set dev "$name" address "$mac"; then
        halow_log_error "bridge: could not pin the MAC address of $name to $mac"
        return 1
    fi
    actual="$(_halow_bridge_read "$sys/$name/address")"
    if [ "${actual,,}" != "$mac" ]; then
        halow_log_error "bridge: the MAC address of $name reads '$actual' after pinning it to $mac"
        return 1
    fi
    if ! _halow_bridge_ip link set dev "$name" type bridge stp_state 0; then
        halow_log_error "bridge: could not turn STP off on $name"
        return 1
    fi
    stp="$(_halow_bridge_read "$sys/$name/bridge/stp_state")"
    if [ "$stp" != "0" ]; then
        halow_log_error "bridge: STP on $name reads '$stp' after turning it off"
        return 1
    fi
    if ! _halow_bridge_ip link set dev "$name" up; then
        halow_log_error "bridge: could not bring $name up"
        return 1
    fi
    return 0
}

# halow_bridge_create <name>
# Marker first, then create, pin the MAC, STP off, up. Idempotent when the bridge already
# exists and is this add-on's (marker held): its settings are re-applied. An existing
# interface of that name that this add-on does not own is refused, never adopted.
# Returns 0 created (or already ours), 1 failed (anything created here was removed again;
# the marker is kept only when that removal could not be confirmed).
halow_bridge_create() {
    local name="${1:-}"
    halow_validate_iface_name "$name" || return 1
    if halow_bridge_exists "$name"; then
        if ! halow_own_check "net_bridge"; then
            halow_log_error "bridge: an interface named $name already exists and this add-on holds no record of creating it; refusing to adopt it"
            return 1
        fi
        if ! halow_bridge_is_bridge "$name"; then
            halow_log_error "bridge: $name exists but is not a bridge device; refusing to use it"
            return 1
        fi
        if ! _halow_bridge_settle "$name"; then
            return 1
        fi
        halow_log_info "bridge: $name already exists and is this add-on's; settings re-applied"
        return 0
    fi

    HALOW_BRIDGE_ISOLATED_IDX=()
    if ! halow_own_mark "net_bridge" "$name"; then
        halow_log_error "bridge: could not record ownership of $name; refusing to create it"
        return 1
    fi
    if ! _halow_bridge_ip link add "$name" type bridge; then
        halow_log_error "bridge: could not create $name"
        if halow_bridge_exists "$name"; then
            halow_log_error "bridge: $name exists although its creation reported failure; ownership kept for rollback"
        else
            halow_own_clear "net_bridge"
        fi
        return 1
    fi
    if ! _halow_bridge_settle "$name"; then
        halow_log_error "bridge: removing $name again after a failed set-up"
        halow_bridge_delete "$name" || true
        return 1
    fi
    halow_log_info "bridge: created $name (MAC pinned, STP off, up)"
    return 0
}

# halow_bridge_delete <name>
# Bring the bridge down, release its ports, delete it, and confirm its absence from the
# host. Works without a marker (the name is enough to recognise this add-on's bridge from
# the host). Clears `net_bridge` only once absence is confirmed. Returns 0 absent, 1 if
# absence could not be confirmed (ownership kept).
halow_bridge_delete() {
    local name="${1:-}" port attempt
    halow_validate_iface_name "$name" || return 1
    HALOW_BRIDGE_ISOLATED_IDX=()   # the ports go with the bridge; a later bridge starts afresh
    if ! halow_bridge_exists "$name"; then
        halow_own_clear "net_bridge"
        return 0
    fi
    _halow_bridge_ip link set dev "$name" down || halow_log_warning "bridge: could not bring $name down before deleting it"
    while IFS= read -r port; do
        [ -n "$port" ] || continue
        _halow_bridge_ip link set dev "$port" nomaster || halow_log_warning "bridge: could not release port $port from $name"
    done < <(halow_bridge_ports "$name")
    _halow_bridge_ip link del dev "$name" || halow_log_warning "bridge: deleting $name reported failure; checking the host"
    for attempt in 1 2 3; do
        if ! halow_bridge_exists "$name"; then
            halow_own_clear "net_bridge"
            halow_log_info "bridge: $name deleted and confirmed absent"
            return 0
        fi
        [ "$attempt" -lt 3 ] && sleep 1
    done
    halow_log_error "bridge: $name is still present after deleting it; ownership kept"
    return 1
}

# halow_bridge_port_add <bridge> <iface>
# Make <iface> a port of <bridge> (idempotent) and bring it up; confirmed from the host.
# An interface that is a port of a DIFFERENT bridge is refused, never moved.
halow_bridge_port_add() {
    local bridge="${1:-}" iface="${2:-}" master
    halow_validate_iface_name "$bridge" || return 1
    halow_validate_iface_name "$iface" || return 1
    if ! halow_bridge_exists "$bridge"; then
        halow_log_error "bridge: cannot add $iface to $bridge: the bridge does not exist"
        return 1
    fi
    if ! halow_bridge_exists "$iface"; then
        halow_log_error "bridge: cannot add $iface to $bridge: the interface does not exist"
        return 1
    fi
    master="$(halow_bridge_port_master "$iface")"
    if [ "$master" = "$bridge" ]; then
        return 0
    fi
    if [ -n "$master" ]; then
        halow_log_error "bridge: $iface is a port of $master, not of $bridge; refusing to move it"
        return 1
    fi
    if ! _halow_bridge_ip link set dev "$iface" master "$bridge"; then
        halow_log_error "bridge: could not add $iface to $bridge"
        return 1
    fi
    master="$(halow_bridge_port_master "$iface")"
    if [ "$master" != "$bridge" ]; then
        halow_log_error "bridge: $iface is not a port of $bridge after adding it"
        return 1
    fi
    _halow_bridge_ip link set dev "$iface" up || halow_log_warning "bridge: could not bring port $iface up"
    halow_log_info "bridge: $iface is now a port of $bridge"
    return 0
}

# halow_bridge_port_remove <iface>
# Release <iface> from whatever bridge it is a port of. Idempotent: an interface that is
# gone, or no longer a port, is already removed. Returns 1 if it is still a port.
halow_bridge_port_remove() {
    local iface="${1:-}" master
    halow_validate_iface_name "$iface" || return 1
    halow_bridge_exists "$iface" || return 0
    master="$(halow_bridge_port_master "$iface")"
    [ -n "$master" ] || return 0
    if ! _halow_bridge_ip link set dev "$iface" nomaster; then
        if ! halow_bridge_exists "$iface"; then
            return 0
        fi
        halow_log_error "bridge: could not release $iface from $master"
        return 1
    fi
    if halow_bridge_exists "$iface" && [ -n "$(halow_bridge_port_master "$iface")" ]; then
        halow_log_error "bridge: $iface is still a port after releasing it"
        return 1
    fi
    halow_log_info "bridge: $iface released from $master"
    return 0
}

# halow_bridge_port_isolate <iface> <on|off>
# Set the bridge port-isolation flag (isolated ports cannot forward to each other; the
# bridge itself, i.e. the gateway, stays reachable) and confirm it from the host.
halow_bridge_port_isolate() {
    local iface="${1:-}" mode="${2:-}" want actual
    halow_validate_iface_name "$iface" || return 1
    case "$mode" in
        on) want=1 ;;
        off) want=0 ;;
        *) halow_log_error "bridge: isolation mode must be on or off (got '$mode')"; return 1 ;;
    esac
    if [ -z "$(halow_bridge_port_master "$iface")" ]; then
        halow_log_error "bridge: cannot set isolation on $iface: it is not a bridge port"
        return 1
    fi
    if ! _halow_bridge_cmd link set dev "$iface" isolated "$mode"; then
        halow_log_error "bridge: could not set isolation $mode on $iface"
        return 1
    fi
    actual="$(_halow_bridge_read "$(_halow_bridge_sys)/$iface/brport/isolated")"
    if [ "$actual" != "$want" ]; then
        halow_log_error "bridge: isolation on $iface reads '$actual' after setting it $mode"
        return 1
    fi
    return 0
}

# halow_bridge_enforce_isolation <bridge>
# Every port of <bridge> (read from the host, whoever added it: hostapd adds the parent
# and the per-station interfaces itself) gets port isolation on, confirmed from the host.
# A port that cannot be isolated is taken out of the bridge (fail closed: an interface
# outside the bridge is dropped by the firewall's catch-all). Returns 0 when every port
# that remains is isolated; 1 if a port could neither be isolated nor removed, or the
# bridge does not exist. Changes nothing for ports that are already isolated.
#
# A NEW port is the normal case, not a fault: hostapd_s1g adds the parent interface when
# it starts and a per-station interface for every bridged (WDS) station that joins, always
# non-isolated, and only the manager can isolate them (at the end of the start, and on
# every supervision tick, about a second, afterwards). That is logged as information. A
# port this process already isolated (same name AND same interface index, so a recreated
# per-station interface does not count) that is found non-isolated again was changed by
# something else: that is the warning. Seen during a supervised test: the line was
# logged at every start for the parent and for the first station, with no ordering fault;
# there are no stations to isolate from before AP-ENABLED, the firewall's catch-all already
# governs the interface, and hostapd's own ap_isolate=1 is rendered.
declare -gA HALOW_BRIDGE_ISOLATED_IDX=()
halow_bridge_enforce_isolation() {
    local bridge="${1:-}" sys port state rc=0 idx
    halow_validate_iface_name "$bridge" || return 1
    if ! halow_bridge_is_bridge "$bridge"; then
        halow_log_error "bridge: cannot enforce port isolation: $bridge does not exist"
        return 1
    fi
    sys="$(_halow_bridge_sys)"
    local -a ports=()
    mapfile -t ports < <(halow_bridge_ports "$bridge")
    for port in "${ports[@]}"; do
        [ -n "$port" ] || continue
        if ! halow_validate_iface_name "$port"; then
            rc=1
            continue
        fi
        state="$(_halow_bridge_read "$sys/$port/brport/isolated")"
        idx="$(_halow_bridge_read "$sys/$port/ifindex")"
        if [ "$state" = "1" ]; then
            [ -z "$idx" ] || HALOW_BRIDGE_ISOLATED_IDX["$port"]="$idx"
            continue
        fi
        if [ -z "$(halow_bridge_port_master "$port")" ]; then
            continue   # left the bridge meanwhile
        fi
        if [ -n "$idx" ] && [ "${HALOW_BRIDGE_ISOLATED_IDX[$port]:-}" = "$idx" ]; then
            halow_log_warning "bridge: port $port of $bridge is no longer isolated (something else changed it); isolating it again"
        else
            halow_log_info "bridge: new port $port of $bridge (added by hostapd_s1g); isolating it"
        fi
        if halow_bridge_port_isolate "$port" on; then
            [ -z "$idx" ] || HALOW_BRIDGE_ISOLATED_IDX["$port"]="$idx"
            continue
        fi
        halow_log_error "bridge: port $port could not be isolated; removing it from $bridge"
        if halow_bridge_port_remove "$port"; then
            continue
        fi
        halow_log_error "bridge: port $port is neither isolated nor removed from $bridge"
        rc=1
    done
    return "$rc"
}
