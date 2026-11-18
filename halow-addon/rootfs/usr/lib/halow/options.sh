#!/usr/bin/env bash
# halow: add-on options.
#
# halow_options_load reads the options into HALOW_CFG_* variables: through bashio inside
# the add-on, otherwise from environment variables HALOW_OPT_<NAME> (upper-case option
# name), so the tests need no bashio. halow_options_validate checks them in a fixed order
# and stops at the first error, naming the option.
#
# Radio model: radio_mode is "automatic" (default) or "manual". In automatic mode any
# saved channel is ignored: it is moved to HALOW_CFG_CHANNEL_SAVED (diagnostics only) and
# HALOW_CFG_CHANNEL is empty, so nothing downstream can use it. Manual mode requires a
# channel valid for the region and bandwidth.
#
# The form always shows `channel` (a required list whose default is the sentinel "auto")
# and `uplink_interface` (a required string whose default is empty), because the Home
# Assistant form hides unset optional ("?") entries behind a switch. "auto" therefore
# means "no channel chosen"; an empty uplink_interface means the same as an absent one
# (the interface of the default route is used).
#
# A bandwidth or radio_mode that is absent, null or empty takes its default and the load logs
# one line per default ("options: bandwidth not supplied, using default 1 MHz"); a supplied
# value is never replaced and logs nothing. The names are kept in HALOW_CFG_DEFAULTED and
# repeated in the "options: valid" summary. Secret values are never logged.
#
# The passphrase is held only in HALOW_CFG_WIFI_PASSPHRASE; it is never logged.
#
# Defines functions and constants only.

HALOW_OPTIONS_NAMES="region radio_mode bandwidth channel wifi_ssid wifi_passphrase halow_subnet_cidr dhcp_range_start dhcp_range_end uplink_interface allowed_ports"

# _halow_options_get <name> — prints the option's value (lists: one entry per line).
_halow_options_get() {
    local name="$1" var val
    if declare -F bashio::config >/dev/null 2>&1; then
        val="$(bashio::config "$name" 2>/dev/null || true)"
        [ "$val" = "null" ] && val=""
        printf '%s' "$val"
        return 0
    fi
    var="HALOW_OPT_${name^^}"
    printf '%s' "${!var:-}"
}

# _halow_options_unquote <value> — strips one pair of surrounding double or single quotes
# and surrounding whitespace (a bandwidth may arrive as 1 or "1").
_halow_options_unquote() {
    local v="$1"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    case "$v" in
        \"*\") v="${v#\"}"; v="${v%\"}" ;;
        \'*\') v="${v#\'}"; v="${v%\'}" ;;
    esac
    printf '%s' "$v"
}

# halow_options_load — always returns 0; validation reports problems.
halow_options_load() {
    local ports line
    HALOW_CFG_REGION="$(_halow_options_unquote "$(_halow_options_get region)")"
    HALOW_CFG_RADIO_MODE="$(_halow_options_unquote "$(_halow_options_get radio_mode)")"
    HALOW_CFG_DEFAULTED=""
    if [ -z "$HALOW_CFG_RADIO_MODE" ]; then
        HALOW_CFG_RADIO_MODE="automatic"
        HALOW_CFG_DEFAULTED="radio_mode"
        halow_log_info "options: radio_mode (Channel selection mode) not supplied, using default automatic"
    fi
    HALOW_CFG_BANDWIDTH="$(_halow_options_unquote "$(_halow_options_get bandwidth)")"
    if [ -z "$HALOW_CFG_BANDWIDTH" ]; then
        HALOW_CFG_BANDWIDTH="${HALOW_DEFAULT_BANDWIDTH_MHZ:-1}"
        HALOW_CFG_DEFAULTED="${HALOW_CFG_DEFAULTED:+$HALOW_CFG_DEFAULTED }bandwidth"
        halow_log_info "options: bandwidth not supplied, using default ${HALOW_CFG_BANDWIDTH} MHz"
    fi
    HALOW_CFG_CHANNEL="$(_halow_options_unquote "$(_halow_options_get channel)")"
    # "auto" is the form's "no channel chosen" value (the schema default), never a channel:
    # it is read exactly like an absent or empty channel.
    [ "$HALOW_CFG_CHANNEL" = "auto" ] && HALOW_CFG_CHANNEL=""
    HALOW_CFG_CHANNEL_SAVED=""
    if [ "$HALOW_CFG_RADIO_MODE" = "automatic" ]; then
        # A saved channel never influences automatic mode.
        HALOW_CFG_CHANNEL_SAVED="$HALOW_CFG_CHANNEL"
        HALOW_CFG_CHANNEL=""
    fi
    HALOW_CFG_WIFI_SSID="$(_halow_options_get wifi_ssid)"
    HALOW_CFG_WIFI_PASSPHRASE="$(_halow_options_get wifi_passphrase)"
    HALOW_CFG_SUBNET_CIDR="$(_halow_options_unquote "$(_halow_options_get halow_subnet_cidr)")"
    HALOW_CFG_DHCP_START="$(_halow_options_unquote "$(_halow_options_get dhcp_range_start)")"
    HALOW_CFG_DHCP_END="$(_halow_options_unquote "$(_halow_options_get dhcp_range_end)")"
    HALOW_CFG_UPLINK="$(_halow_options_unquote "$(_halow_options_get uplink_interface)")"
    ports="$(_halow_options_get allowed_ports)"
    ports="${ports//,/ }"
    HALOW_CFG_ALLOWED_PORTS=""
    while IFS= read -r line; do
        for line in $line; do
            line="$(_halow_options_unquote "$line")"
            line="${line#[}"; line="${line%]}"; line="${line%,}"
            line="$(_halow_options_unquote "$line")"
            [ -n "$line" ] && HALOW_CFG_ALLOWED_PORTS="${HALOW_CFG_ALLOWED_PORTS}${line} "
        done
    done <<< "$ports"
    HALOW_CFG_ALLOWED_PORTS="${HALOW_CFG_ALLOWED_PORTS% }"
    HALOW_CFG_MAX_STATIONS=""
    HALOW_CFG_ERROR_CODE=""
    HALOW_CFG_ERROR_OPTION=""
    HALOW_CFG_ERROR_REASON=""
    return 0
}

# _halow_options_error <CODE> <option> <reason>
_halow_options_error() {
    HALOW_CFG_ERROR_CODE="$1"
    HALOW_CFG_ERROR_OPTION="$2"
    HALOW_CFG_ERROR_REASON="$3"
    halow_log_error "options: $2: $3 ($1)"
    return 1
}

# _halow_options_need <function...> — 0 if every named function exists.
_halow_options_need() {
    local fn
    for fn in "$@"; do
        if ! declare -F "$fn" >/dev/null 2>&1; then
            _halow_options_error INTERNAL_ERROR "" "the validator $fn is not available"
            return 1
        fi
    done
}

# halow_options_validate
# 0 when every option is valid; 1 with HALOW_CFG_ERROR_CODE, HALOW_CFG_ERROR_OPTION and
# HALOW_CFG_ERROR_REASON set for the first error, in this order:
#   wifi_ssid, wifi_passphrase, region (REGION_UNVALIDATED), radio_mode, bandwidth, the
#   radio choice (channel in manual mode), halow_subnet_cidr, the DHCP range, a collision
#   of the subnet with the host's networks, the DHCP pool size, allowed_ports,
#   uplink_interface. Sets HALOW_CFG_MAX_STATIONS on success.
halow_options_validate() {
    local out first opt reason rc
    HALOW_CFG_ERROR_CODE=""
    HALOW_CFG_ERROR_OPTION=""
    HALOW_CFG_ERROR_REASON=""
    _halow_options_need halow_validate_ssid halow_validate_passphrase halow_radio_profile_exists \
        halow_radio_validate halow_validate_ipv4_cidr halow_validate_dhcp_range \
        halow_subnet_collision halow_max_stations halow_allowlist_validate halow_validate_uplink_name || return 1

    if ! halow_validate_ssid "$HALOW_CFG_WIFI_SSID"; then
        _halow_options_error CONFIG_INVALID wifi_ssid "must be 1-32 bytes with no line breaks or backslash"
        return 1
    fi
    if [ -z "$HALOW_CFG_WIFI_PASSPHRASE" ] || ! halow_validate_passphrase "$HALOW_CFG_WIFI_PASSPHRASE"; then
        _halow_options_error CONFIG_INVALID wifi_passphrase "is missing or has an invalid length or characters"
        return 1
    fi
    if [ -z "$HALOW_CFG_REGION" ] || ! halow_radio_profile_exists "$HALOW_CFG_REGION"; then
        _halow_options_error REGION_UNVALIDATED region "region '${HALOW_CFG_REGION}' has no validated radio profile for this adapter"
        return 1
    fi
    case "$HALOW_CFG_RADIO_MODE" in
        automatic|manual) : ;;
        *)
            _halow_options_error CONFIG_INVALID radio_mode "Channel selection mode (radio_mode) must be automatic or manual"
            return 1
            ;;
    esac
    case "$HALOW_CFG_BANDWIDTH" in
        ''|*[!0-9]*)
            _halow_options_error CONFIG_INVALID bandwidth "must be a whole number of MHz"
            return 1
            ;;
    esac
    if [ "$HALOW_CFG_RADIO_MODE" = "manual" ]; then
        case "$HALOW_CFG_CHANNEL" in
            ''|*[!0-9]*)
                _halow_options_error CONFIG_INVALID channel "manual mode requires a channel number"
                return 1
                ;;
        esac
    fi
    if out="$(halow_radio_validate "$HALOW_CFG_REGION" "$HALOW_CFG_RADIO_MODE" "$HALOW_CFG_BANDWIDTH" "$HALOW_CFG_CHANNEL" 2>/dev/null)"; then
        rc=0
    else
        rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
        first="${out%%$'\n'*}"
        opt=""; reason="not valid for region ${HALOW_CFG_REGION}"
        case "$first" in
            OPTION=*)
                opt="${first#OPTION=}"
                opt="${opt%% *}"
                case "$first" in *" REASON="*) reason="${first#* REASON=}" ;; esac
                ;;
        esac
        case "$opt" in
            bandwidth|channel|radio_mode|region) : ;;
            *) if [ "$HALOW_CFG_RADIO_MODE" = "manual" ]; then opt="channel"; else opt="bandwidth"; fi ;;
        esac
        _halow_options_error CONFIG_INVALID "$opt" "$reason"
        return 1
    fi
    if ! halow_validate_ipv4_cidr "$HALOW_CFG_SUBNET_CIDR"; then
        _halow_options_error CONFIG_INVALID halow_subnet_cidr "must be an IPv4 gateway address with a prefix length, for example 192.168.90.1/24"
        return 1
    fi
    if ! halow_validate_ipv4_cidr "${HALOW_CFG_DHCP_START}/32" || [ -z "$HALOW_CFG_DHCP_START" ]; then
        _halow_options_error CONFIG_INVALID dhcp_range_start "must be an IPv4 address"
        return 1
    fi
    if ! halow_validate_ipv4_cidr "${HALOW_CFG_DHCP_END}/32" || [ -z "$HALOW_CFG_DHCP_END" ]; then
        _halow_options_error CONFIG_INVALID dhcp_range_end "must be an IPv4 address"
        return 1
    fi
    if ! halow_validate_dhcp_range "$HALOW_CFG_DHCP_START" "$HALOW_CFG_DHCP_END" "$HALOW_CFG_SUBNET_CIDR"; then
        _halow_options_error CONFIG_INVALID dhcp_range_start "the range must be ordered, inside the subnet, and must not include the gateway, network or broadcast address"
        return 1
    fi
    if out="$(halow_subnet_collision "$HALOW_CFG_SUBNET_CIDR" 2>/dev/null)"; then
        rc=0
    else
        rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
        _halow_options_error CONFIG_INVALID halow_subnet_cidr "collides with a network already on the host${out:+: ${out%%$'\n'*}}"
        return 1
    fi
    if ! HALOW_CFG_MAX_STATIONS="$(halow_max_stations "$HALOW_CFG_DHCP_START" "$HALOW_CFG_DHCP_END" 2>/dev/null)"; then
        HALOW_CFG_MAX_STATIONS=""
    fi
    case "$HALOW_CFG_MAX_STATIONS" in
        ''|*[!0-9]*|0)
            HALOW_CFG_MAX_STATIONS=""
            _halow_options_error CONFIG_INVALID dhcp_range_end "the DHCP pool must hold at least one address"
            return 1
            ;;
    esac
    # shellcheck disable=SC2086
    if out="$(halow_allowlist_validate $HALOW_CFG_ALLOWED_PORTS 2>/dev/null)"; then
        rc=0
    else
        rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
        _halow_options_error CONFIG_INVALID allowed_ports "${out%%$'\n'*}"
        return 1
    fi
    # Only a plausible physical or network interface: never ".", "..", a leading "-", a
    # container or virtual network (which would open that network to HaLow clients), or
    # the add-on's own bridge or radio interface.
    if [ -n "$HALOW_CFG_UPLINK" ] && ! halow_validate_uplink_name "$HALOW_CFG_UPLINK"; then
        _halow_options_error CONFIG_INVALID uplink_interface "is not an acceptable uplink interface name (a physical network interface such as end0 or eth0; not a container, virtual or HaLow interface)"
        return 1
    fi
    halow_log_info "options: valid (region ${HALOW_CFG_REGION}, ${HALOW_CFG_RADIO_MODE} mode, ${HALOW_CFG_BANDWIDTH} MHz${HALOW_CFG_CHANNEL:+, channel ${HALOW_CFG_CHANNEL}}${HALOW_CFG_CHANNEL_SAVED:+; saved channel ${HALOW_CFG_CHANNEL_SAVED} ignored in automatic mode}${HALOW_CFG_DEFAULTED:+; defaults applied for: ${HALOW_CFG_DEFAULTED}})"
    return 0
}
