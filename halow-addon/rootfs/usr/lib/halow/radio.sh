#!/usr/bin/env bash
# halow: radio and region profiles, radio option validation, hostapd_s1g configuration
# rendering, automatic channel selection (ACS) handling and effective-value capture.
#
# Library only: defines functions and one path default, runs nothing when sourced, is
# re-sourceable, and is safe under errexit/errtrace/nounset/pipefail/inherit_errexit.
#
# The profile table is data (rootfs/usr/share/halow/radio_profiles.psv), keyed by
# (adapter identity, region), one row per supported bandwidth. See the header of that
# file for the column layout and for the pinned upstream sources every value comes from.
#
# Nothing in this file has been exercised on the target device. Every width is at most
# "implemented" and every fallback channel at most a "candidate" until live evidence is
# recorded in the table. In particular the hostapd_cli "status" field names and units and
# the ACS event format are taken from the pinned hostap source and await live validation.

# Location of this library at source time; the default table path is derived from it so
# the same default works in the image (/usr/lib/halow -> /usr/share/halow) and in the
# source tree (rootfs/usr/lib/halow -> rootfs/usr/share/halow).
case "${BASH_SOURCE[0]:-}" in
    */*) _HALOW_RADIO_LIB_DIR="${BASH_SOURCE[0]%/*}" ;;
    *)   _HALOW_RADIO_LIB_DIR="." ;;
esac
: "${HALOW_RADIO_PROFILES:=${_HALOW_RADIO_LIB_DIR}/../../share/halow/radio_profiles.psv}"

# ---------------------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------------------

_halow_radio_log_error() {
    if declare -F halow_log_error >/dev/null 2>&1; then
        halow_log_error "$*"
    else
        printf '[halow] ERROR: %s\n' "$*" >&2
    fi
}

_halow_radio_log_info() {
    if declare -F halow_log_info >/dev/null 2>&1; then
        halow_log_info "$*"
    else
        printf '[halow] INFO: %s\n' "$*" >&2
    fi
}

# The identity of the one supported adapter ("<vendor>:<product>").
_halow_radio_adapter_id() {
    printf '%s:%s' "${HALOW_ADAPTER_VENDOR_ID:-325b}" "${HALOW_ADAPTER_PRODUCT_ID:-8100}"
}

# _halow_radio_is_uint <value> : 0 if a plain decimal integer without sign or leading zero.
_halow_radio_is_uint() {
    case "$1" in
        0) return 0 ;;
        ''|0*|*[!0-9]*) return 1 ;;
    esac
    [ "${#1}" -le 9 ]
}

# _halow_radio_safe <value> : printable rendering of a customer value for a reason text
# (one line, restricted characters, bounded length).
_halow_radio_safe() {
    local v="${1//[!A-Za-z0-9._ -]/?}"
    printf '%s' "${v:0:32}"
}

# _halow_radio_load : parse the table into
#   _HALOW_RADIO_REGION_ROW["<adapter>|<region>"] = "country|scheme|hw_mode|ah|fstart|sep|beacon|dtim|capab"
#   _HALOW_RADIO_WIDTH_ROW["<adapter>|<region>|<bw>"] = "op_class|state|prim_w|prim_i|fallback|fb_state|channels"
#   _HALOW_RADIO_WIDTHS["<adapter>|<region>"] = "1 2 4 8" (file order)
#   _HALOW_RADIO_REGIONS = "<adapter>|<region> ..." (file order)
# Fails closed (1, tables emptied) on a missing file or on any malformed row.
_halow_radio_load() {
    declare -gA _HALOW_RADIO_REGION_ROW=() _HALOW_RADIO_WIDTH_ROW=() _HALOW_RADIO_WIDTHS=()
    _HALOW_RADIO_REGIONS=""
    local file="${HALOW_RADIO_PROFILES}" line n=0 bad=0
    if [ ! -r "$file" ]; then
        _halow_radio_log_error "radio: profile table not readable: $file"
        return 1
    fi
    local kind adapter region f4 f5 f6 f7 f8 f9 f10 f11 f12 extra
    local ch pair cfreq chbad
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        line="${line%$'\r'}"
        case "$line" in ''|'#'*) continue ;; esac
        kind="" adapter="" region="" f4="" f5="" f6="" f7="" f8="" f9="" f10="" f11="" f12="" extra=""
        IFS='|' read -r kind adapter region f4 f5 f6 f7 f8 f9 f10 f11 f12 extra <<< "$line"
        case "$region" in ''|*[!A-Za-z0-9_]*) bad=1; _halow_radio_log_error "radio: table line $n: bad region"; continue ;; esac
        case "$adapter" in ''|*[!0-9a-fA-F:]*) bad=1; _halow_radio_log_error "radio: table line $n: bad adapter"; continue ;; esac
        case "$kind" in
            region)
                if [ -n "$extra" ] || [ -z "$f12" ] \
                   || ! _halow_radio_is_uint "$f5" || ! _halow_radio_is_uint "$f7" \
                   || ! _halow_radio_is_uint "$f8" || ! _halow_radio_is_uint "$f9" \
                   || ! _halow_radio_is_uint "$f10" || ! _halow_radio_is_uint "$f11"; then
                    bad=1; _halow_radio_log_error "radio: table line $n: malformed region row"; continue
                fi
                case "$f4" in [A-Z][A-Z]) : ;; *) bad=1; _halow_radio_log_error "radio: table line $n: bad country code"; continue ;; esac
                case "$f6" in ''|*[!a-z]*) bad=1; _halow_radio_log_error "radio: table line $n: bad hw_mode"; continue ;; esac
                case "$f12" in *[!][A-Z0-9-]*) bad=1; _halow_radio_log_error "radio: table line $n: bad s1g_capab"; continue ;; esac
                if [ -n "${_HALOW_RADIO_REGION_ROW["$adapter|$region"]+x}" ]; then
                    bad=1; _halow_radio_log_error "radio: table line $n: duplicate region row"; continue
                fi
                _HALOW_RADIO_REGION_ROW["$adapter|$region"]="$f4|$f5|$f6|$f7|$f8|$f9|$f10|$f11|$f12"
                _HALOW_RADIO_REGIONS="${_HALOW_RADIO_REGIONS}${adapter}|${region} "
                ;;
            width)
                if [ -n "$f12" ] || [ -n "$extra" ] || [ -z "$f11" ] \
                   || ! _halow_radio_is_uint "$f4" || ! _halow_radio_is_uint "$f5" \
                   || ! _halow_radio_is_uint "$f7" || ! _halow_radio_is_uint "$f8"; then
                    bad=1; _halow_radio_log_error "radio: table line $n: malformed width row"; continue
                fi
                case "$f6" in implemented|live-validated) : ;; *) bad=1; _halow_radio_log_error "radio: table line $n: bad width state"; continue ;; esac
                case "$f10" in candidate|live-validated|-) : ;; *) bad=1; _halow_radio_log_error "radio: table line $n: bad fallback state"; continue ;; esac
                if [ "$f9" != "-" ] && ! _halow_radio_is_uint "$f9"; then
                    bad=1; _halow_radio_log_error "radio: table line $n: bad fallback channel"; continue
                fi
                # Primary-channel rules of the hostap fork (src/utils/morse.c
                # morse_check_valid_s1g_prim_1Mhz_chan_index(): index <= width - 1;
                # hostapd/config_file.c hostapd_config_s1g_val(): primary width (1 or 2 MHz)
                # must not exceed the operating width).
                if [ "$f7" -gt 1 ] || [ "$f8" -gt $((f4 - 1)) ] || { [ "$f7" -eq 1 ] && [ "$f4" -lt 2 ]; }; then
                    bad=1; _halow_radio_log_error "radio: table line $n: invalid primary channel width/index for $f4 MHz"; continue
                fi
                chbad=0
                for pair in $f11; do
                    ch="${pair%%:*}"; cfreq="${pair#*:}"
                    if [ "$pair" = "$ch" ] || ! _halow_radio_is_uint "$ch" || ! _halow_radio_is_uint "$cfreq"; then
                        chbad=1
                    fi
                done
                if [ "$f9" != "-" ] && [ "$chbad" -eq 0 ]; then
                    # The fallback channel must be one of the width's own channels.
                    chbad=2
                    for pair in $f11; do
                        [ "${pair%%:*}" = "$f9" ] && chbad=0
                    done
                fi
                if [ "$chbad" -ne 0 ]; then
                    bad=1; _halow_radio_log_error "radio: table line $n: malformed channel list or fallback outside it"; continue
                fi
                if [ -n "${_HALOW_RADIO_WIDTH_ROW["$adapter|$region|$f4"]+x}" ]; then
                    bad=1; _halow_radio_log_error "radio: table line $n: duplicate width row"; continue
                fi
                _HALOW_RADIO_WIDTH_ROW["$adapter|$region|$f4"]="$f5|$f6|$f7|$f8|$f9|$f10|$f11"
                _HALOW_RADIO_WIDTHS["$adapter|$region"]="${_HALOW_RADIO_WIDTHS["$adapter|$region"]:-}${_HALOW_RADIO_WIDTHS["$adapter|$region"]:+ }$f4"
                ;;
            *)
                bad=1; _halow_radio_log_error "radio: table line $n: unknown row kind"
                ;;
        esac
    done < "$file"
    # A width row without its region row is a malformed table.
    local key
    for key in "${!_HALOW_RADIO_WIDTHS[@]}"; do
        if [ -z "${_HALOW_RADIO_REGION_ROW["$key"]+x}" ]; then
            bad=1; _halow_radio_log_error "radio: width rows without a region row for $key"
        fi
    done
    if [ "$bad" -ne 0 ]; then
        declare -gA _HALOW_RADIO_REGION_ROW=() _HALOW_RADIO_WIDTH_ROW=() _HALOW_RADIO_WIDTHS=()
        _HALOW_RADIO_REGIONS=""
        return 1
    fi
    return 0
}

# _halow_radio_region_field <region> <index 1..9> : prints one region-row field.
_halow_radio_region_field() {
    local region="$1" idx="$2" row key
    key="$(_halow_radio_adapter_id)|$region"
    _halow_radio_load || return 1
    [ -n "${_HALOW_RADIO_REGION_ROW["$key"]+x}" ] || return 1
    [ -n "${_HALOW_RADIO_WIDTHS["$key"]:-}" ] || return 1
    row="${_HALOW_RADIO_REGION_ROW["$key"]}"
    local -a f
    IFS='|' read -r -a f <<< "$row"
    printf '%s' "${f[$((idx - 1))]}"
}

# _halow_radio_width_field <region> <bw> <index 1..7> : prints one width-row field.
_halow_radio_width_field() {
    local region="$1" bw="$2" idx="$3" row key
    _halow_radio_is_uint "$bw" || return 1
    key="$(_halow_radio_adapter_id)|$region|$bw"
    _halow_radio_load || return 1
    [ -n "${_HALOW_RADIO_WIDTH_ROW["$key"]+x}" ] || return 1
    row="${_HALOW_RADIO_WIDTH_ROW["$key"]}"
    local -a f
    IFS='|' read -r -a f <<< "$row"
    printf '%s' "${f[$((idx - 1))]}"
}

# _halow_radio_channel_in_set <region> <bw> <channel> : 0 if the channel is in the set.
_halow_radio_channel_in_set() {
    local list pair
    if ! list="$(_halow_radio_width_field "$1" "$2" 7)"; then return 1; fi
    for pair in $list; do
        [ "${pair%%:*}" = "$3" ] && return 0
    done
    return 1
}

# _halow_radio_freq_to_channel <region> <bw-or-empty> <freq_khz> : prints the channel of
# the region (any width when bw is empty) whose centre frequency is exactly <freq_khz>.
# A channel number is a function of the centre frequency within one channelisation, so
# at most one channel matches.
_halow_radio_freq_to_channel() {
    local region="$1" bw="$2" freq="$3" w widths list pair
    if [ -n "$bw" ]; then
        widths="$bw"
    elif ! widths="$(halow_radio_widths "$region")"; then
        return 1
    fi
    for w in $widths; do
        if ! list="$(_halow_radio_width_field "$region" "$w" 7)"; then continue; fi
        for pair in $list; do
            if [ "${pair#*:}" = "$freq" ]; then
                printf '%s' "${pair%%:*}"
                return 0
            fi
        done
    done
    return 1
}

# _halow_radio_default_region : prints the region when the table holds exactly one region
# for the supported adapter (used only to label values when a caller gives no region).
_halow_radio_default_region() {
    local entry count=0 found="" adapter
    adapter="$(_halow_radio_adapter_id)"
    _halow_radio_load || return 1
    for entry in $_HALOW_RADIO_REGIONS; do
        if [ "${entry%%|*}" = "$adapter" ]; then
            count=$((count + 1)); found="${entry#*|}"
        fi
    done
    [ "$count" -eq 1 ] || return 1
    printf '%s' "$found"
}

# _halow_radio_freq_khz <text> : normalises an S1G centre frequency to kHz. The pinned
# hostap source reports kHz (morse_s1g_op_class_chan_to_freq()); a decimal MHz value in
# the S1G range (e.g. 923.5) is also accepted. Anything else fails.
_halow_radio_freq_khz() {
    local v="$1" mhz frac
    if _halow_radio_is_uint "$v"; then
        if [ "$v" -ge 750000 ] && [ "$v" -le 950000 ]; then printf '%s' "$v"; return 0; fi
        if [ "$v" -ge 750 ] && [ "$v" -le 950 ]; then printf '%s' "$((v * 1000))"; return 0; fi
        return 1
    fi
    if [[ "$v" =~ ^([0-9]{3})\.([0-9]{1,3})$ ]]; then
        mhz="${BASH_REMATCH[1]}"; frac="${BASH_REMATCH[2]}"
        while [ "${#frac}" -lt 3 ]; do frac="${frac}0"; done
        if [ "$((10#$mhz))" -ge 750 ] && [ "$((10#$mhz))" -le 950 ]; then
            printf '%s' "$((10#$mhz * 1000 + 10#$frac))"
            return 0
        fi
    fi
    return 1
}

# ---------------------------------------------------------------------------------------
# Profile queries
# ---------------------------------------------------------------------------------------

# halow_radio_profile_exists <region> : 0 if (the supported adapter, region) has a profile
# with at least one width. Unknown adapter, unknown region or an unreadable/malformed
# table fail closed (non-zero).
halow_radio_profile_exists() {
    local key
    [ -n "${1:-}" ] || return 1
    key="$(_halow_radio_adapter_id)|$1"
    _halow_radio_load || return 1
    [ -n "${_HALOW_RADIO_REGION_ROW["$key"]+x}" ] && [ -n "${_HALOW_RADIO_WIDTHS["$key"]:-}" ]
}

# halow_radio_widths <region> : prints the supported widths, e.g. "1 2 4 8".
halow_radio_widths() {
    halow_radio_profile_exists "${1:-}" || return 1
    printf '%s\n' "${_HALOW_RADIO_WIDTHS["$(_halow_radio_adapter_id)|$1"]}"
}

# halow_radio_width_state <region> <bw_mhz> : prints implemented | live-validated.
halow_radio_width_state() {
    local s
    if ! s="$(_halow_radio_width_field "${1:-}" "${2:-}" 2)"; then return 1; fi
    printf '%s\n' "$s"
}

# halow_radio_channels <region> <bw_mhz> : prints "<channel> <frequency_khz>" per line.
halow_radio_channels() {
    local list pair
    if ! list="$(_halow_radio_width_field "${1:-}" "${2:-}" 7)"; then return 1; fi
    for pair in $list; do
        printf '%s %s\n' "${pair%%:*}" "${pair#*:}"
    done
}

# halow_radio_channel_freq <region> <bw_mhz> <channel> : prints the centre frequency (kHz).
halow_radio_channel_freq() {
    local list pair
    if ! list="$(_halow_radio_width_field "${1:-}" "${2:-}" 7)"; then return 1; fi
    for pair in $list; do
        if [ "${pair%%:*}" = "${3:-}" ]; then printf '%s\n' "${pair#*:}"; return 0; fi
    done
    return 1
}

# halow_radio_primary_info <region> <bw_mhz> <channel>
# Derives the effective primary channel configuration from the profile table alone (no
# runtime tool is called). Sets, in the calling shell (never call it in a command
# substitution): HALOW_PRIM_OP_CLASS, HALOW_PRIM_CHANNEL, HALOW_PRIM_WIDTH_MHZ,
# HALOW_PRIM_BW_MHZ (primary bandwidth, 1 or 2), HALOW_PRIM_INDEX, HALOW_PRIM_CENTRE_KHZ,
# HALOW_PRIM_1MHZ_CHANNEL and HALOW_PRIM_1MHZ_KHZ (both empty when the primary is not
# 1 MHz). Returns 1, with every value empty, for an unknown region, width or channel.
# The 1 MHz primary follows the hostap fork's morse_calculate_primary_s1g_channel() for
# centre channels up to 50: primary = centre - (width - 1) + 2 x index, where a channel
# step is 500 kHz and the 1 MHz sub-channels of a <width> MHz channel sit 2 steps apart
# (1 MHz: the channel itself; 2 MHz: centre -1 / +1; 4 MHz: centre -3 .. +3; 8 MHz:
# centre -7 .. +7). The frequency is the region's start frequency plus separation x channel.
halow_radio_primary_info() {
    local region="${1:-}" bw="${2:-}" ch="${3:-}" fstart sep op prim_w prim_i centre
    HALOW_PRIM_OP_CLASS="" HALOW_PRIM_CHANNEL="" HALOW_PRIM_WIDTH_MHZ="" HALOW_PRIM_BW_MHZ=""
    HALOW_PRIM_INDEX="" HALOW_PRIM_CENTRE_KHZ="" HALOW_PRIM_1MHZ_CHANNEL="" HALOW_PRIM_1MHZ_KHZ=""
    _halow_radio_is_uint "$ch" || return 1
    op="$(_halow_radio_width_field "$region" "$bw" 1)" || return 1
    prim_w="$(_halow_radio_width_field "$region" "$bw" 3)" || return 1
    prim_i="$(_halow_radio_width_field "$region" "$bw" 4)" || return 1
    centre="$(halow_radio_channel_freq "$region" "$bw" "$ch")" || return 1
    fstart="$(_halow_radio_region_field "$region" 5)" || return 1
    sep="$(_halow_radio_region_field "$region" 6)" || return 1
    HALOW_PRIM_OP_CLASS="$op"
    HALOW_PRIM_CHANNEL="$ch"
    HALOW_PRIM_WIDTH_MHZ="$bw"
    HALOW_PRIM_BW_MHZ=$((prim_w + 1))
    HALOW_PRIM_INDEX="$prim_i"
    HALOW_PRIM_CENTRE_KHZ="$centre"
    if [ "$prim_w" -eq 0 ]; then
        HALOW_PRIM_1MHZ_CHANNEL=$((ch - (bw - 1) + 2 * prim_i))
        HALOW_PRIM_1MHZ_KHZ=$((fstart + sep * HALOW_PRIM_1MHZ_CHANNEL))
    fi
    return 0
}

# halow_radio_op_class <region> <bw_mhz> : prints the operating class (internal value).
halow_radio_op_class() {
    local v
    if ! v="$(_halow_radio_width_field "${1:-}" "${2:-}" 1)"; then return 1; fi
    printf '%s\n' "$v"
}

# halow_radio_fallback_channel <region> <bw_mhz> : prints the fallback channel; 1 if none.
halow_radio_fallback_channel() {
    local v
    if ! v="$(_halow_radio_width_field "${1:-}" "${2:-}" 5)"; then return 1; fi
    [ "$v" != "-" ] || return 1
    printf '%s\n' "$v"
}

# halow_radio_fallback_state <region> <bw_mhz> : prints candidate | live-validated.
halow_radio_fallback_state() {
    local v
    if ! v="$(_halow_radio_width_field "${1:-}" "${2:-}" 6)"; then return 1; fi
    [ "$v" != "-" ] || return 1
    printf '%s\n' "$v"
}

# halow_radio_country <region> : prints the country code.
halow_radio_country() {
    local v
    if ! v="$(_halow_radio_region_field "${1:-}" 1)"; then return 1; fi
    printf '%s\n' "$v"
}

# halow_radio_scheme <region> : prints the channelisation scheme number for dot11ah.
halow_radio_scheme() {
    local v
    if ! v="$(_halow_radio_region_field "${1:-}" 2)"; then return 1; fi
    printf '%s\n' "$v"
}

# ---------------------------------------------------------------------------------------
# Option validation
# ---------------------------------------------------------------------------------------

# halow_radio_validate <region> <mode> <bw_mhz> <channel>
# 0 valid. 1 invalid; the first stdout line is "OPTION=<name> REASON=<text>" with <name>
# one of region, radio_mode, bandwidth, channel. Automatic mode ignores <channel>
# entirely (any value, including garbage, is accepted and never used). Manual mode
# requires a channel of the region's set for the selected width. The literal "null"
# (an unset optional option as some option readers report it) counts as not provided.
halow_radio_validate() {
    local region="${1:-}" mode="${2:-}" bw="${3:-}" channel="${4:-}" widths list pair valid=""
    if ! halow_radio_profile_exists "$region"; then
        printf 'OPTION=region REASON=region %s has no validated radio profile for this adapter\n' "'$(_halow_radio_safe "$region")'"
        return 1
    fi
    case "$mode" in
        automatic|manual) : ;;
        *)
            printf 'OPTION=radio_mode REASON=unknown Channel selection mode (radio_mode) %s (use automatic or manual)\n' "'$(_halow_radio_safe "$mode")'"
            return 1
            ;;
    esac
    widths="$(halow_radio_widths "$region")"
    if ! _halow_radio_is_uint "$bw" || [ -z "${_HALOW_RADIO_WIDTH_ROW["$(_halow_radio_adapter_id)|$region|$bw"]+x}" ]; then
        printf 'OPTION=bandwidth REASON=bandwidth %s MHz is not supported in region %s (supported: %s MHz)\n' \
            "'$(_halow_radio_safe "$bw")'" "$region" "$widths"
        return 1
    fi
    [ "$mode" = "automatic" ] && return 0
    if [ -z "$channel" ] || [ "$channel" = "null" ]; then
        printf 'OPTION=channel REASON=channel not provided: manual mode requires a channel\n'
        return 1
    fi
    if ! _halow_radio_is_uint "$channel"; then
        printf 'OPTION=channel REASON=channel %s is not a whole number\n' "'$(_halow_radio_safe "$channel")'"
        return 1
    fi
    list="$(_halow_radio_width_field "$region" "$bw" 7)"
    for pair in $list; do
        valid="${valid}${valid:+ }${pair%%:*}"
    done
    if ! _halow_radio_channel_in_set "$region" "$bw" "$channel"; then
        printf 'OPTION=channel REASON=channel %s is not valid for %s MHz in region %s (valid channels: %s)\n' \
            "$channel" "$bw" "$region" "$valid"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------------------

# halow_radio_render <region> <mode:automatic|manual|fallback> <bw_mhz> <channel> <iface>
#                    <ssid> <passphrase> <bridge> <max_stations> <dest>
# Renders the hostapd_s1g configuration at <dest> (which must be inside HALOW_RUN_DIR)
# from the bundled template ${HALOW_ARTIFACTS_DIR}/hostapd_s1g.conf.
#
# Radio keys come from the profile: country_code, hw_mode, ieee80211ah, op_class,
# s1g_prim_chwidth, s1g_prim_1mhz_chan_index, s1g_capab, beacon_int, dtim_period.
# channel:
#   automatic -> "channel=acs_survey". In the pinned hostap fork (hostapd/config_file.c,
#                key "channel") both "acs_survey" and "0" set acs=1 and channel=0, after
#                which hostapd_config_s1g_val() validates only country + operating class.
#                acs_survey is used because it is explicit and because a build without
#                ACS rejects it with a configuration error instead of misbehaving.
#                Any <channel> argument is ignored and never written.
#   manual     -> the numeric channel, which must be valid for the region and width.
#   fallback   -> the profile's fallback channel for the width, rendered exactly like
#                manual. <channel> must be empty or equal to that fallback channel.
# Also: bridge=<bridge> when given, ap_isolate=1, max_num_sta=<max_stations>, wds_sta=1,
# and logger_syslog_level=2 / logger_stdout_level=2 (informational level, so no debug
# line can carry key material). ctrl_interface and the WPA3-SAE settings stay as in the
# template. Any active passphrase/key line of the template is dropped.
#
# Secret handling and publication are delegated to halow_render_hostapd_config
# (hostapd_config.sh): interface/ssid substitution through awk -v, the passphrase line
# written by the shell builtin printf, temporary file created under umask 077, mode 0600
# verified after publication and the file removed again if that cannot be confirmed.
# The intermediate radio template written here holds no secret and is removed.
#
# On success sets HALOW_RADIO_RENDER_MODE, HALOW_RADIO_RENDER_CHANNEL (empty for
# automatic) and HALOW_RADIO_RENDER_FREQ_KHZ (empty for automatic). Prints nothing.
halow_radio_render() {
    local region="${1:-}" mode="${2:-}" bw="${3:-}" channel="${4:-}" iface="${5:-}"
    local ssid="${6:-}" passphrase="${7:-}" bridge="${8:-}" max_sta="${9:-}" dest="${10:-}"
    local template="${HALOW_ARTIFACTS_DIR:-/opt/halow/artifacts}/hostapd_s1g.conf"
    local run_dir="${HALOW_RUN_DIR:-/run/halow}"
    local country hwmode ah beacon dtim capab op_class prim_w prim_i ch_value freq="" out
    HALOW_RADIO_RENDER_MODE=""
    HALOW_RADIO_RENDER_CHANNEL=""
    HALOW_RADIO_RENDER_FREQ_KHZ=""

    case "$dest" in
        "$run_dir"/*) : ;;
        *) _halow_radio_log_error "radio: refusing to render outside the run directory"; return 1 ;;
    esac
    case "/$dest/" in
        */../*|*/./*) _halow_radio_log_error "radio: refusing a destination path with dot components"; return 1 ;;
    esac
    if [ ! -f "$template" ]; then
        _halow_radio_log_error "radio: hostapd template not found: $template"
        return 1
    fi
    if ! halow_radio_profile_exists "$region"; then
        _halow_radio_log_error "radio: no radio profile for region $(_halow_radio_safe "$region")"
        return 1
    fi
    if ! op_class="$(_halow_radio_width_field "$region" "$bw" 1)"; then
        _halow_radio_log_error "radio: bandwidth $(_halow_radio_safe "$bw") MHz is not supported in region $region"
        return 1
    fi
    case "$mode" in
        automatic)
            ch_value="acs_survey"
            ;;
        manual)
            if ! out="$(halow_radio_validate "$region" manual "$bw" "$channel")"; then
                _halow_radio_log_error "radio: invalid manual channel: ${out%%$'\n'*}"
                return 1
            fi
            ch_value="$channel"
            ;;
        fallback)
            local fb
            if ! fb="$(halow_radio_fallback_channel "$region" "$bw")"; then
                _halow_radio_log_error "radio: no fallback channel for $bw MHz in region $region"
                return 1
            fi
            if [ -n "$channel" ] && [ "$channel" != "$fb" ]; then
                _halow_radio_log_error "radio: fallback rendering requested with channel $(_halow_radio_safe "$channel"), which is not the profile fallback $fb"
                return 1
            fi
            if ! _halow_radio_channel_in_set "$region" "$bw" "$fb"; then
                _halow_radio_log_error "radio: fallback channel $fb is not in the $bw MHz set of region $region"
                return 1
            fi
            ch_value="$fb"
            ;;
        *)
            _halow_radio_log_error "radio: unknown render mode $(_halow_radio_safe "$mode")"
            return 1
            ;;
    esac
    if [ "$ch_value" != "acs_survey" ]; then
        freq="$(halow_radio_channel_freq "$region" "$bw" "$ch_value")"
    fi
    if ! halow_validate_iface_name "$iface"; then
        _halow_radio_log_error "radio: invalid interface name"
        return 1
    fi
    if [ -n "$bridge" ] && ! halow_validate_iface_name "$bridge"; then
        _halow_radio_log_error "radio: invalid bridge name"
        return 1
    fi
    if ! halow_validate_ssid "$ssid"; then
        return 1
    fi
    if ! halow_validate_passphrase "$passphrase"; then
        return 1
    fi
    if ! _halow_radio_is_uint "$max_sta" || [ "$max_sta" -lt 1 ] || [ "$max_sta" -gt 2007 ]; then
        _halow_radio_log_error "radio: max_stations must be 1-2007"
        return 1
    fi

    country="$(_halow_radio_region_field "$region" 1)"
    hwmode="$(_halow_radio_region_field "$region" 3)"
    ah="$(_halow_radio_region_field "$region" 4)"
    beacon="$(_halow_radio_region_field "$region" 7)"
    dtim="$(_halow_radio_region_field "$region" 8)"
    capab="$(_halow_radio_region_field "$region" 9)"
    prim_w="$(_halow_radio_width_field "$region" "$bw" 3)"
    prim_i="$(_halow_radio_width_field "$region" "$bw" 4)"

    local settings="$dest.radio-settings.$$" radio_tpl="$dest.radio-template.$$"
    if ! ( umask 077 && : > "$settings" && : > "$radio_tpl" ); then
        _halow_radio_log_error "radio: could not create intermediate files next to $dest"
        rm -f -- "$settings" "$radio_tpl"
        return 1
    fi
    {
        printf 'country_code=%s\n' "$country"
        printf 'hw_mode=%s\n' "$hwmode"
        printf 'ieee80211ah=%s\n' "$ah"
        printf 'op_class=%s\n' "$op_class"
        printf 'channel=%s\n' "$ch_value"
        printf 's1g_prim_chwidth=%s\n' "$prim_w"
        printf 's1g_prim_1mhz_chan_index=%s\n' "$prim_i"
        printf 's1g_capab=%s\n' "$capab"
        printf 'beacon_int=%s\n' "$beacon"
        printf 'dtim_period=%s\n' "$dtim"
        printf 'max_num_sta=%s\n' "$max_sta"
        printf 'ap_isolate=1\n'
        printf 'wds_sta=1\n'
        printf 'logger_syslog_level=2\n'
        printf 'logger_stdout_level=2\n'
        [ -n "$bridge" ] && printf 'bridge=%s\n' "$bridge"
        :
    } > "$settings" || { rm -f -- "$settings" "$radio_tpl"; return 1; }

    # First file: key=value settings. Second file: the template. A set key replaces the
    # template's first active line for it (later active duplicates are dropped); a key the
    # template lacks is appended. Active passphrase/key lines and an active bridge line
    # without a configured bridge are dropped.
    if ! awk -v have_bridge="${bridge:+1}" '
        FNR == NR {
            i = index($0, "="); k = substr($0, 1, i - 1)
            val[k] = $0; order[++n] = k; next
        }
        {
            if ($0 ~ /^[A-Za-z0-9_]+=/) {
                i = index($0, "="); k = substr($0, 1, i - 1)
                if (k == "wpa_passphrase" || k == "wpa_psk" || k == "sae_password" || k == "wpa_psk_file") next
                if (k == "bridge" && have_bridge != "1") next
                if (k in val) {
                    if (!(k in done)) { print val[k]; done[k] = 1 }
                    next
                }
            }
            print
        }
        END {
            for (j = 1; j <= n; j++) if (!(order[j] in done)) print val[order[j]]
        }
    ' "$settings" "$template" > "$radio_tpl"; then
        _halow_radio_log_error "radio: rendering the radio template failed"
        rm -f -- "$settings" "$radio_tpl"
        return 1
    fi
    rm -f -- "$settings"

    local rc
    if halow_render_hostapd_config "$radio_tpl" "$iface" "$ssid" "$passphrase" "$dest"; then
        rc=0
    else
        rc=$?
    fi
    rm -f -- "$radio_tpl"
    if [ "$rc" -ne 0 ]; then
        return "$rc"
    fi
    HALOW_RADIO_RENDER_MODE="$mode"
    if [ "$ch_value" != "acs_survey" ]; then
        HALOW_RADIO_RENDER_CHANNEL="$ch_value"
        HALOW_RADIO_RENDER_FREQ_KHZ="$freq"
    fi
    _halow_radio_log_info "radio: rendered region=$region mode=$mode bandwidth=${bw}MHz op_class=$op_class channel=$ch_value"
    return 0
}

# ---------------------------------------------------------------------------------------
# Automatic channel selection
# ---------------------------------------------------------------------------------------

# _halow_radio_acs_scan <log> <skip_lines> : sets _HALOW_RADIO_ACS_EVENT (""|completed|failed)
# and _HALOW_RADIO_ACS_LINE from the last ACS event after the last ACS-STARTED line (so an
# event from an earlier run in the same log does not count once a new run has started)
# and after the first <skip_lines> lines.
_halow_radio_acs_scan() {
    local log="$1" skip="$2" line n=0
    _HALOW_RADIO_ACS_EVENT=""
    _HALOW_RADIO_ACS_LINE=""
    [ -f "$log" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        [ "$n" -le "$skip" ] && continue
        case "$line" in
            *"ACS-STARTED"*)   _HALOW_RADIO_ACS_EVENT=""; _HALOW_RADIO_ACS_LINE="" ;;
            *"ACS-COMPLETED "*) _HALOW_RADIO_ACS_EVENT="completed"; _HALOW_RADIO_ACS_LINE="$line" ;;
            *"ACS-FAILED"*)    _HALOW_RADIO_ACS_EVENT="failed"; _HALOW_RADIO_ACS_LINE="$line" ;;
        esac
    done < "$log"
    return 0
}

# halow_radio_acs_wait <log_file> <pid> <timeout_s> [<region>] [<skip_lines>] [<bandwidth_mhz>]
# Polls the hostapd log (every HALOW_RADIO_ACS_POLL_S seconds, default 1) for the outcome
# of automatic channel selection. If HALOW_RADIO_POLL_HOOK names a shell function, it is
# called once per poll iteration (its return value and output are ignored), so a caller
# can keep a heartbeat during the wait. With <bandwidth_mhz> a completion counts only if
# its frequency is a channel of that width (an off-width completion is 1, so the caller
# uses the fallback for the selected width):
#   0 completed: "ACS-COMPLETED freq=<f> channel=<c>". Sets HALOW_ACS_FREQ_KHZ and
#     HALOW_ACS_CHANNEL. In the pinned hostap fork (src/ap/hw_features.c
#     hostapd_acs_completed()) freq is the S1G centre frequency in kHz and channel the S1G
#     channel; this function does not trust the reported channel: it derives the channel
#     from the frequency through the region's table (<region>, or the only region of the
#     supported adapter), and HALOW_ACS_REPORTED_CHANNEL keeps the reported value. A
#     completion whose frequency cannot be parsed or is not a channel of the region is
#     treated as a failure (1), because its result cannot be trusted.
#   1 failed: "ACS-FAILED" (hostapd disables the interface but may keep running).
#   2 timeout after <timeout_s> seconds.
#   3 hostapd (<pid>) exited without a result.
# HALOW_ACS_REASON carries a short reason on non-zero. Event format awaits live validation.
halow_radio_acs_wait() {
    local log="${1:-}" pid="${2:-}" timeout="${3:-}" region="${4:-}" skip="${5:-0}" bw="${6:-}"
    local poll="${HALOW_RADIO_ACS_POLL_S:-1}" start="$SECONDS" khz ch rep
    local hook="${HALOW_RADIO_POLL_HOOK:-}"
    HALOW_ACS_FREQ_KHZ=""
    HALOW_ACS_CHANNEL=""
    HALOW_ACS_REPORTED_CHANNEL=""
    HALOW_ACS_REASON=""
    if ! _halow_radio_is_uint "$timeout" || [ "$timeout" -lt 1 ]; then
        HALOW_ACS_REASON="invalid timeout"
        return 1
    fi
    _halow_radio_is_uint "$skip" || skip=0
    if [ -n "$bw" ] && ! _halow_radio_is_uint "$bw"; then
        HALOW_ACS_REASON="invalid bandwidth"
        return 1
    fi
    if [ -z "$region" ]; then
        region="$(_halow_radio_default_region 2>/dev/null)" || region=""
    fi
    if [ -n "$hook" ] && ! declare -F "$hook" >/dev/null 2>&1; then
        hook=""
    fi
    local alive
    while :; do
        if [ -n "$hook" ]; then
            "$hook" >/dev/null 2>&1 || :
        fi
        alive=1
        if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
            alive=0
        fi
        # Scan after the liveness probe so lines written just before an exit are seen.
        _halow_radio_acs_scan "$log" "$skip"
        case "$_HALOW_RADIO_ACS_EVENT" in
            completed)
                rep=""
                if [[ "$_HALOW_RADIO_ACS_LINE" =~ channel=(-?[0-9]+) ]]; then rep="${BASH_REMATCH[1]}"; fi
                HALOW_ACS_REPORTED_CHANNEL="$rep"
                if [[ ! "$_HALOW_RADIO_ACS_LINE" =~ freq=([0-9.]+) ]] || ! khz="$(_halow_radio_freq_khz "${BASH_REMATCH[1]}")"; then
                    HALOW_ACS_REASON="completion reported an unparseable frequency"
                    return 1
                fi
                if [ -z "$region" ] || ! ch="$(_halow_radio_freq_to_channel "$region" "" "$khz")"; then
                    HALOW_ACS_REASON="completion frequency $khz kHz is not a channel of the region"
                    return 1
                fi
                if [ -n "$bw" ] && ! ch="$(_halow_radio_freq_to_channel "$region" "$bw" "$khz")"; then
                    HALOW_ACS_REASON="completion frequency $khz kHz is not a $bw MHz channel of the region"
                    return 1
                fi
                HALOW_ACS_FREQ_KHZ="$khz"
                HALOW_ACS_CHANNEL="$ch"
                return 0
                ;;
            failed)
                HALOW_ACS_REASON="hostapd reported ACS-FAILED"
                return 1
                ;;
        esac
        if [ "$alive" -eq 0 ]; then
            HALOW_ACS_REASON="hostapd exited before channel selection finished"
            return 3
        fi
        if [ $((SECONDS - start)) -ge "$timeout" ]; then
            HALOW_ACS_REASON="channel selection did not finish within ${timeout}s"
            return 2
        fi
        sleep "$poll"
    done
}

# ---------------------------------------------------------------------------------------
# Effective values
# ---------------------------------------------------------------------------------------

# halow_radio_parse_status <text> [<region>]
# Parses "hostapd_cli status" output. Field names and units follow the pinned hostap
# fork (src/ap/ctrl_iface_ap.c hostapd_ctrl_iface_status()): s1g_freq (S1G centre
# frequency, kHz), s1g_bw (operating width, MHz), s1g_prim_chwidth (primary width in MHz,
# 1 or 2), s1g_prim_1mhz_chan_index, then the HT-mapped freq (MHz, 5 GHz) and channel
# (HT number) and state. They await live validation on the target device.
# Sets HALOW_EFF_FREQ_KHZ HALOW_EFF_BW_MHZ HALOW_EFF_PRIM_WIDTH HALOW_EFF_PRIM_INDEX
# HALOW_EFF_CHANNEL (S1G channel derived from the S1G frequency through the region table;
# empty if it is not a channel of the region), plus HALOW_EFF_HT_FREQ_MHZ,
# HALOW_EFF_HT_CHANNEL and HALOW_EFF_STATE when present. Returns 1 (every value cleared,
# HALOW_EFF_REASON set) if any S1G field is missing or garbled: that is "cannot capture",
# never success.
halow_radio_parse_status() {
    local text="${1:-}" region="${2:-}" line k v
    local s_freq="" s_bw="" s_pw="" s_pi="" h_freq="" h_ch="" st=""
    local got_freq=0 got_bw=0 got_pw=0 got_pi=0
    HALOW_EFF_FREQ_KHZ="" HALOW_EFF_BW_MHZ="" HALOW_EFF_PRIM_WIDTH="" HALOW_EFF_PRIM_INDEX=""
    HALOW_EFF_CHANNEL="" HALOW_EFF_HT_FREQ_MHZ="" HALOW_EFF_HT_CHANNEL="" HALOW_EFF_STATE=""
    HALOW_EFF_REASON=""
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        case "$line" in *=*) : ;; *) continue ;; esac
        k="${line%%=*}"; v="${line#*=}"
        case "$k" in
            s1g_freq)                 [ "$got_freq" -eq 0 ] && { s_freq="$v"; got_freq=1; } ;;
            s1g_bw)                   [ "$got_bw" -eq 0 ] && { s_bw="$v"; got_bw=1; } ;;
            s1g_prim_chwidth)         [ "$got_pw" -eq 0 ] && { s_pw="$v"; got_pw=1; } ;;
            s1g_prim_1mhz_chan_index) [ "$got_pi" -eq 0 ] && { s_pi="$v"; got_pi=1; } ;;
            freq)                     [ -z "$h_freq" ] && h_freq="$v" ;;
            channel)                  [ -z "$h_ch" ] && h_ch="$v" ;;
            state)                    [ -z "$st" ] && st="$v" ;;
        esac
        :
    done <<< "$text"
    if [ "$got_freq" -eq 0 ] || [ "$got_bw" -eq 0 ] || [ "$got_pw" -eq 0 ] || [ "$got_pi" -eq 0 ]; then
        HALOW_EFF_REASON="status output lacks one or more S1G fields"
        return 1
    fi
    local khz
    if ! khz="$(_halow_radio_freq_khz "$s_freq")"; then
        HALOW_EFF_REASON="s1g_freq is not an S1G frequency"
        return 1
    fi
    case "$s_bw" in 1|2|4|8|16) : ;; *) HALOW_EFF_REASON="s1g_bw is not a valid width"; return 1 ;; esac
    case "$s_pw" in 1|2) : ;; *) HALOW_EFF_REASON="s1g_prim_chwidth is not 1 or 2"; return 1 ;; esac
    if ! _halow_radio_is_uint "$s_pi" || [ "$s_pi" -gt 15 ]; then
        HALOW_EFF_REASON="s1g_prim_1mhz_chan_index is garbled"
        return 1
    fi
    HALOW_EFF_FREQ_KHZ="$khz"
    HALOW_EFF_BW_MHZ="$s_bw"
    HALOW_EFF_PRIM_WIDTH="$s_pw"
    HALOW_EFF_PRIM_INDEX="$s_pi"
    _halow_radio_is_uint "$h_freq" && HALOW_EFF_HT_FREQ_MHZ="$h_freq"
    _halow_radio_is_uint "$h_ch" && HALOW_EFF_HT_CHANNEL="$h_ch"
    case "$st" in *[!A-Z_]*) st="" ;; esac
    HALOW_EFF_STATE="$st"
    if [ -z "$region" ]; then
        region="$(_halow_radio_default_region 2>/dev/null)" || region=""
    fi
    if [ -n "$region" ]; then
        HALOW_EFF_CHANNEL="$(_halow_radio_freq_to_channel "$region" "" "$khz" 2>/dev/null)" || HALOW_EFF_CHANNEL=""
    fi
    return 0
}

# halow_radio_capture_effective <hostapd_cli-command...>
# Runs "<command...> status" (for example the bundled hostapd_cli_s1g with its -p/-i
# arguments) through "timeout HALOW_RADIO_CLI_TIMEOUT_S" (default 5 s, so a control
# interface that never answers cannot hang the caller), then parses it. 0 captured;
# 1 the command failed, timed out or its output lacks or garbles the expected fields:
# every HALOW_EFF_* value is cleared and HALOW_EFF_STATE is set to "unavailable" ("cannot
# capture", which is not a mismatch). A shell function given as the command (tests only)
# is called directly, since timeout can run only programs.
halow_radio_capture_effective() {
    local out limit="${HALOW_RADIO_CLI_TIMEOUT_S:-5}"
    HALOW_EFF_FREQ_KHZ="" HALOW_EFF_BW_MHZ="" HALOW_EFF_PRIM_WIDTH="" HALOW_EFF_PRIM_INDEX=""
    HALOW_EFF_CHANNEL="" HALOW_EFF_HT_FREQ_MHZ="" HALOW_EFF_HT_CHANNEL="" HALOW_EFF_STATE=""
    HALOW_EFF_REASON=""
    if [ "$#" -lt 1 ]; then
        HALOW_EFF_REASON="no status command given"
        HALOW_EFF_STATE="unavailable"
        return 1
    fi
    _halow_radio_is_uint "$limit" && [ "$limit" -ge 1 ] || limit=5
    if declare -F "$1" >/dev/null 2>&1; then
        if ! out="$("$@" status 2>/dev/null)"; then
            HALOW_EFF_REASON="the status command failed"
            HALOW_EFF_STATE="unavailable"
            return 1
        fi
    elif ! out="$(timeout "$limit" "$@" status 2>/dev/null)"; then
        HALOW_EFF_REASON="the status command failed or did not answer within ${limit}s"
        HALOW_EFF_STATE="unavailable"
        return 1
    fi
    if ! halow_radio_parse_status "$out"; then
        HALOW_EFF_STATE="unavailable"
        return 1
    fi
    return 0
}

# halow_radio_check_effective <region> <bw_mhz> <channel-or-empty>
# Compares the captured HALOW_EFF_* values with the selected profile. 0 consistent;
# 1 RADIO_MISMATCH with a one-line reason on stdout when: nothing was captured; the
# reported state is not ENABLED; the reported width differs from the selected one; the
# frequency is not a channel of the width's set; the primary width or index differs from
# the profile; or (manual/fallback: <channel> given) the channel differs. In automatic
# mode (<channel> empty) any channel of the width's set is consistent. On 0 sets
# HALOW_EFF_CHANNEL to the S1G channel derived from the frequency.
halow_radio_check_effective() {
    local region="${1:-}" bw="${2:-}" expected="${3:-}" ch pw pi pw_mhz
    if [ -z "${HALOW_EFF_FREQ_KHZ:-}" ] || [ -z "${HALOW_EFF_BW_MHZ:-}" ]; then
        printf 'cannot check: the effective radio values were not captured\n'
        return 1
    fi
    if ! halow_radio_profile_exists "$region" || ! _halow_radio_width_field "$region" "$bw" 1 >/dev/null; then
        printf 'cannot check: no radio profile for region %s at %s MHz\n' "$(_halow_radio_safe "$region")" "$(_halow_radio_safe "$bw")"
        return 1
    fi
    if [ -n "${HALOW_EFF_STATE:-}" ] && [ "$HALOW_EFF_STATE" != "ENABLED" ]; then
        printf 'access point state is %s, not ENABLED\n' "$HALOW_EFF_STATE"
        return 1
    fi
    if [ "$HALOW_EFF_BW_MHZ" != "$bw" ]; then
        printf 'operating width is %s MHz, selected %s MHz\n' "$HALOW_EFF_BW_MHZ" "$bw"
        return 1
    fi
    if ! ch="$(_halow_radio_freq_to_channel "$region" "$bw" "$HALOW_EFF_FREQ_KHZ")"; then
        printf 'operating frequency %s kHz is not a %s MHz channel of region %s\n' "$HALOW_EFF_FREQ_KHZ" "$bw" "$region"
        return 1
    fi
    if [ -n "$expected" ] && [ "$ch" != "$expected" ]; then
        printf 'operating channel is %s (%s kHz), selected channel %s\n' "$ch" "$HALOW_EFF_FREQ_KHZ" "$(_halow_radio_safe "$expected")"
        return 1
    fi
    pw="$(_halow_radio_width_field "$region" "$bw" 3)"
    pi="$(_halow_radio_width_field "$region" "$bw" 4)"
    pw_mhz=$(( pw == 1 ? 2 : 1 ))
    if [ -n "${HALOW_EFF_PRIM_WIDTH:-}" ] && [ "$HALOW_EFF_PRIM_WIDTH" != "$pw_mhz" ]; then
        printf 'primary channel width is %s MHz, profile %s MHz\n' "$HALOW_EFF_PRIM_WIDTH" "$pw_mhz"
        return 1
    fi
    if [ -n "${HALOW_EFF_PRIM_INDEX:-}" ] && [ "$HALOW_EFF_PRIM_INDEX" != "$pi" ]; then
        printf 'primary 1 MHz channel index is %s, profile %s\n' "$HALOW_EFF_PRIM_INDEX" "$pi"
        return 1
    fi
    HALOW_EFF_CHANNEL="$ch"
    return 0
}

# ---------------------------------------------------------------------------------------
# Release readiness
# ---------------------------------------------------------------------------------------

# halow_radio_release_readiness
# Prints one line per (region, width) and per fallback of the supported adapter with its
# state, marking each that is not live-validated as outstanding, then a summary line.
# 0 only when every width and every fallback is live-validated; 1 otherwise (also when
# the table is unreadable, malformed or holds no region for the adapter, a width has
# no fallback, or a width required for a region (HALOW_RADIO_REQUIRED_WIDTHS, entries
# "<region>:<w> <w> ..." separated by ";"; default AU: 1 2 4 8) is missing from the table).
: "${HALOW_RADIO_REQUIRED_WIDTHS:=AU:1 2 4 8}"
halow_radio_release_readiness() {
    local adapter entry region w row outstanding=0 total=0
    local op state pw pi fb fbs list req rreg rwidths
    adapter="$(_halow_radio_adapter_id)"
    if ! _halow_radio_load; then
        printf 'radio profile table unreadable or malformed: not release-ready\n'
        return 1
    fi
    local -a reqs
    IFS=';' read -r -a reqs <<< "$HALOW_RADIO_REQUIRED_WIDTHS"
    for req in "${reqs[@]}"; do
        rreg="${req%%:*}"; rreg="${rreg// /}"
        [ -n "$rreg" ] && [ "$req" != "$rreg" ] || continue
        rwidths="${req#*:}"
        for w in $rwidths; do
            if [ -z "${_HALOW_RADIO_WIDTH_ROW["$adapter|$rreg|$w"]+x}" ] || [ -z "${_HALOW_RADIO_REGION_ROW["$adapter|$rreg"]+x}" ]; then
                printf 'region=%s width_mhz=%s MISSING OUTSTANDING (required width not in the profile table)\n' "$rreg" "$w"
                total=$((total + 1))
                outstanding=$((outstanding + 1))
            fi
        done
    done
    for entry in $_HALOW_RADIO_REGIONS; do
        [ "${entry%%|*}" = "$adapter" ] || continue
        region="${entry#*|}"
        for w in ${_HALOW_RADIO_WIDTHS["$entry"]:-}; do
            row="${_HALOW_RADIO_WIDTH_ROW["$entry|$w"]}"
            IFS='|' read -r op state pw pi fb fbs list <<< "$row"
            total=$((total + 1))
            if [ "$state" = "live-validated" ]; then
                printf 'region=%s width_mhz=%s state=%s\n' "$region" "$w" "$state"
            else
                printf 'region=%s width_mhz=%s state=%s OUTSTANDING (needs live validation)\n' "$region" "$w" "$state"
                outstanding=$((outstanding + 1))
            fi
            total=$((total + 1))
            if [ "$fb" = "-" ]; then
                printf 'region=%s width_mhz=%s fallback=none OUTSTANDING (no fallback channel)\n' "$region" "$w"
                outstanding=$((outstanding + 1))
            elif [ "$fbs" = "live-validated" ]; then
                printf 'region=%s width_mhz=%s fallback_channel=%s fallback_state=%s\n' "$region" "$w" "$fb" "$fbs"
            else
                printf 'region=%s width_mhz=%s fallback_channel=%s fallback_state=%s OUTSTANDING (needs live validation)\n' "$region" "$w" "$fb" "$fbs"
                outstanding=$((outstanding + 1))
            fi
        done
    done
    if [ "$total" -eq 0 ]; then
        printf 'no radio profile for adapter %s: not release-ready\n' "$adapter"
        return 1
    fi
    printf 'outstanding=%s of %s\n' "$outstanding" "$total"
    [ "$outstanding" -eq 0 ]
}
