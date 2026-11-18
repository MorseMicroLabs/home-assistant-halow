#!/usr/bin/env bash
# halow: the status snapshot (status.json, schema 2) written by the manager and read by
# the unprivileged status service.
#
# Schema 2 changed the station records of schema 1 ({mac, online, ip, last_seen, kind}):
# a station is now {mac, online, online_source, kind, connected_since, state_changed_at, ips[], devices[],
# devices_omitted}; see halow_state_stations_set. "last_seen" and the single "ip" are gone
# because neither was truthful (the first was the time of the last connection event, not of
# any activity; the second guessed one address for a station that may have several devices
# behind it). The status service accepts only schema 2.
#
# The manager is the only writer. All state is kept in this shell (global associative
# arrays) and every flush rewrites the whole snapshot atomically: a temporary file in the
# same directory, mode 0644, then a rename, so a reader never sees a half-written file.
# JSON is built here in pure bash; no JSON tool is needed in the image.
#
# Every string that enters the snapshot (and the diagnostics log tail) passes through
# halow_redact first and halow_json_escape when written, so a passphrase, a passphrase
# assignment or a 64-hex-digit key never reaches the file, and hostile text (quotes,
# backslashes, control characters, invalid UTF-8) cannot break the JSON.
#
# Flushing: every setter except halow_state_diag_set and halow_state_diag_log_append
# flushes the snapshot immediately (and so also refreshes updated_at). The two diagnostics
# setters only update memory; their values are written by the next flush or heartbeat.
# A setter returns non-zero only for an invalid argument; a failed write is reported on
# stderr and surfaces on the page as a stale status (halow_state_flush itself returns 1).
#
# Library rules: defines functions only, never runs anything when sourced, re-sourceable,
# safe under errexit/nounset/pipefail/inherit_errexit. Depends on errors.sh for the
# catalogue wording (sourced alongside it).

: "${HALOW_STATE_LOG_MAX:=200}"
: "${HALOW_STATE_LOG_LINE_MAX:=2000}"
: "${HALOW_STATE_DIAG_MAX:=256}"
: "${HALOW_STATE_STATIONS_MAX:=1024}"
: "${HALOW_STATE_DEVICES_MAX:=2048}"
: "${HALOW_STATE_DEVICES_PER_STATION_MAX:=32}"
: "${HALOW_STATE_IPS_MAX:=8}"

declare -gA _HALOW_ST
declare -gA _HALOW_ST_DIAG
declare -ga _HALOW_ST_DIAG_KEYS
declare -ga _HALOW_ST_LOG
# Prebuilt JSON array of the stations (each value already redacted and escaped).
_HALOW_ST_STATIONS_JSON="${_HALOW_ST_STATIONS_JSON:-[]}"

# Scratch outputs of the internal helpers (avoid command substitution forks).
_HALOW_JSON_OUT=""
_HALOW_REDACT_OUT=""
_HALOW_STATE_J=""
_HALOW_STATE_NOW=0

_HALOW_REDACTED="[redacted]"

# ---------------------------------------------------------------------------------------
# JSON escaping
# ---------------------------------------------------------------------------------------

# _halow_state_json_escape_into <string> — sets _HALOW_JSON_OUT to the escaped body.
# Printable ASCII is copied (with " and \ escaped); control characters become \uXXXX (or
# the short escapes); well-formed UTF-8 is copied unchanged; any byte that is not part of
# a well-formed UTF-8 sequence becomes �, so the result is always valid JSON text.
_halow_state_json_escape_into() {
    local LC_ALL=C
    local s="${1-}"
    if [[ $s != *[^\ -~]* ]]; then
        s="${s//\\/\\\\}"
        s="${s//\"/\\\"}"
        _HALOW_JSON_OUT="$s"
        return 0
    fi
    local out="" c u i=0 n=${#s} b b2 need lo hi j ok
    while (( i < n )); do
        c="${s:i:1}"
        if [[ $c == [\ -~] ]]; then
            case "$c" in
                '"') out+='\"' ;;
                '\') out+='\\' ;;
                *) out+="$c" ;;
            esac
            i=$((i + 1))
            continue
        fi
        printf -v b '%d' "'$c"
        if (( b < 0 )); then b=$((b + 256)); fi
        if (( b < 128 )); then
            case "$b" in
                8) out+='\b' ;;
                9) out+='\t' ;;
                10) out+='\n' ;;
                12) out+='\f' ;;
                13) out+='\r' ;;
                *) printf -v u '\\u%04x' "$b"; out+="$u" ;;
            esac
            i=$((i + 1))
            continue
        fi
        need=0; lo=128; hi=191
        if (( b >= 0xC2 && b <= 0xDF )); then need=1
        elif (( b == 0xE0 )); then need=2; lo=0xA0
        elif (( (b >= 0xE1 && b <= 0xEC) || b == 0xEE || b == 0xEF )); then need=2
        elif (( b == 0xED )); then need=2; hi=0x9F
        elif (( b == 0xF0 )); then need=3; lo=0x90
        elif (( b >= 0xF1 && b <= 0xF3 )); then need=3
        elif (( b == 0xF4 )); then need=3; hi=0x8F
        fi
        ok=0
        if (( need > 0 && i + need < n )); then
            ok=1
            for (( j = 1; j <= need; j++ )); do
                printf -v b2 '%d' "'${s:i+j:1}"
                if (( b2 < 0 )); then b2=$((b2 + 256)); fi
                if (( j == 1 )); then
                    if (( b2 < lo || b2 > hi )); then ok=0; break; fi
                elif (( b2 < 128 || b2 > 191 )); then
                    ok=0; break
                fi
            done
        fi
        if (( ok )); then
            out+="${s:i:need+1}"
            i=$((i + need + 1))
        else
            out+='�'
            i=$((i + 1))
        fi
    done
    _HALOW_JSON_OUT="$out"
}

# halow_json_escape <string> — prints the string escaped for a JSON string body (no
# surrounding quotes, no trailing newline).
halow_json_escape() {
    _halow_state_json_escape_into "${1-}"
    printf '%s' "$_HALOW_JSON_OUT"
}

# ---------------------------------------------------------------------------------------
# Redaction
# ---------------------------------------------------------------------------------------

# Key words whose value is a secret (matched case-insensitively).
_HALOW_REDACT_KEYS='(passphrase|password|passwd|psk|secret|token)'

# _halow_state_redact_line_into <line> — sets _HALOW_REDACT_OUT (one line, no newline).
_halow_state_redact_line_into() {
    local line="${1-}" rest acc
    local re_json='^(.*"[^"]*'"$_HALOW_REDACT_KEYS"'[^"]*"[[:space:]]*:[[:space:]]*")(([^"\\]|\\.)*)(".*)$'
    local re_assign='^(.*)'"$_HALOW_REDACT_KEYS"'('"'"'?[[:space:]]*[=:]).*$'
    local re_hex='^(.*[^0-9A-Fa-f]|)[0-9A-Fa-f]{64,}([^0-9A-Fa-f].*|)$'
    # JSON style "...passphrase...": "value"  (value replaced, structure kept)
    rest="$line"; acc=""
    while [[ $rest =~ $re_json ]]; do
        acc="${_HALOW_REDACTED}${BASH_REMATCH[5]}${acc}"
        rest="${BASH_REMATCH[1]}"
    done
    line="${rest}${acc}"
    # assignment style passphrase=value / password: value  (redacted to the end of the line)
    rest="$line"; acc=""
    while [[ $rest =~ $re_assign ]]; do
        acc="${BASH_REMATCH[2]}${BASH_REMATCH[3]}${_HALOW_REDACTED}"
        rest="${BASH_REMATCH[1]}"
    done
    line="${rest}${acc}"
    # 64 (or more) consecutive hex digits: a derived key
    rest="$line"; acc=""
    while [[ $rest =~ $re_hex ]]; do
        acc="${_HALOW_REDACTED}${BASH_REMATCH[2]}${acc}"
        rest="${BASH_REMATCH[1]}"
    done
    _HALOW_REDACT_OUT="${rest}${acc}"
}

# _halow_state_redact_into <string> — sets _HALOW_REDACT_OUT.
_halow_state_redact_into() {
    local s="${1-}" known="${HALOW_CFG_WIFI_PASSPHRASE:-}" extra="${HALOW_REDACT_SECRET:-}"
    # The Supervisor token values, should the manager's environment carry them.
    local tok1="${SUPERVISOR_TOKEN:-}" tok2="${HASSIO_TOKEN:-}"
    local lower="${s,,}"
    if [[ $lower != *pass* && $lower != *psk* && $lower != *secret* && $lower != *token* ]] \
       && ! [[ $s =~ [0-9A-Fa-f]{64} ]] \
       && { [ -z "$known" ] || [[ $s != *"$known"* ]]; } \
       && { [ -z "$extra" ] || [[ $s != *"$extra"* ]]; } \
       && { [ -z "$tok1" ] || [[ $s != *"$tok1"* ]]; } \
       && { [ -z "$tok2" ] || [[ $s != *"$tok2"* ]]; }; then
        _HALOW_REDACT_OUT="$s"
        return 0
    fi
    # The configured passphrase itself, wherever it appears (a caller's mistake), and the
    # other known secret values.
    if [ -n "$known" ]; then s="${s//"$known"/$_HALOW_REDACTED}"; fi
    if [ -n "$extra" ]; then s="${s//"$extra"/$_HALOW_REDACTED}"; fi
    if [ -n "$tok1" ]; then s="${s//"$tok1"/$_HALOW_REDACTED}"; fi
    if [ -n "$tok2" ]; then s="${s//"$tok2"/$_HALOW_REDACTED}"; fi
    local restore_nocase=0
    if ! shopt -q nocasematch; then shopt -s nocasematch; restore_nocase=1; fi
    local rest="$s" out="" line
    while :; do
        if [[ $rest == *$'\n'* ]]; then
            line="${rest%%$'\n'*}"
            rest="${rest#*$'\n'}"
            _halow_state_redact_line_into "$line"
            out+="${_HALOW_REDACT_OUT}"$'\n'
        else
            _halow_state_redact_line_into "$rest"
            out+="${_HALOW_REDACT_OUT}"
            break
        fi
    done
    if (( restore_nocase )); then shopt -u nocasematch; fi
    _HALOW_REDACT_OUT="$out"
}

# halow_redact <string> — prints the string with secrets removed: values of passphrase,
# wpa_passphrase, password, psk, secret and token assignments (key=value, key: value),
# JSON-style "key":"value" pairs with such a key, runs of 64 or more hex digits, and the
# configured passphrase (HALOW_CFG_WIFI_PASSPHRASE), HALOW_REDACT_SECRET and the Supervisor
# token values (SUPERVISOR_TOKEN, HASSIO_TOKEN) wherever they appear.
halow_redact() {
    _halow_state_redact_into "${1-}"
    printf '%s' "$_HALOW_REDACT_OUT"
}

# ---------------------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------------------

# Seconds since the epoch into _HALOW_STATE_NOW. HALOW_STATE_NOW (digits) overrides the
# clock for tests.
_halow_state_now() {
    if [[ ${HALOW_STATE_NOW:-} =~ ^[0-9]+$ ]]; then
        _HALOW_STATE_NOW="$HALOW_STATE_NOW"
    else
        printf -v _HALOW_STATE_NOW '%(%s)T' -1
    fi
}

_halow_state_file() {
    printf '%s' "${HALOW_STATUS_FILE:-${HALOW_RUN_DIR:-/run/halow}/status.json}"
}

# _halow_state_clean <string> — redacted copy into _HALOW_REDACT_OUT.
_halow_state_clean() {
    _halow_state_redact_into "${1-}"
}

_halow_state_defaults() {
    _halow_state_now
    _HALOW_ST=()
    _HALOW_ST[schema]=2
    _HALOW_ST[started_at]="$_HALOW_STATE_NOW"
    _HALOW_ST[updated_at]="$_HALOW_STATE_NOW"
    _HALOW_ST[boot_id]=""
    _HALOW_ST[overall]="starting"
    _HALOW_ST[att_set]=0
    _HALOW_ST[att_last_code]=""
    _HALOW_ST[att_last_since]=""
    _HALOW_ST[adv_set]=0
    _HALOW_ST[region]=""
    _HALOW_ST[radio_mode]=""
    _HALOW_ST[req_bw]=""
    _HALOW_ST[req_channel]=""
    _HALOW_ST[eff_set]=0
    _HALOW_ST[last_set]=0
    _HALOW_ST[adapter_present]=false
    _HALOW_ST[adapter_iface]=""
    _HALOW_ST[backend_applied]=false
    _HALOW_ST[backend_bridge]=""
    _HALOW_ST[backend_subnet]=""
    _HALOW_ST[backend_gateway]=""
    _HALOW_ST_STATIONS_JSON="[]"
    _HALOW_ST_DIAG=()
    _HALOW_ST_DIAG_KEYS=()
    _HALOW_ST_LOG=()
}

_halow_state_ensure() {
    if [ -z "${_HALOW_ST[schema]-}" ]; then _halow_state_defaults; fi
}

_halow_state_read_boot_id() {
    local id="" path="${HALOW_BOOT_ID_PATH:-/proc/sys/kernel/random/boot_id}"
    if [ -r "$path" ]; then
        { IFS= read -r id < "$path"; } 2>/dev/null || :
    fi
    _halow_state_clean "$id"
    _HALOW_ST[boot_id]="$_HALOW_REDACT_OUT"
}

# Append to _HALOW_STATE_J: a JSON string, a non-negative integer (or null), a boolean.
_halow_state_jq() {
    _halow_state_json_escape_into "${1-}"
    _HALOW_STATE_J+="\"${_HALOW_JSON_OUT}\""
}
_halow_state_jn() {
    local v="${1-}"
    if [[ $v =~ ^[0-9]+$ ]] && (( ${#v} <= 18 )); then
        _HALOW_STATE_J+="$((10#$v))"
    else
        _HALOW_STATE_J+="null"
    fi
}
_halow_state_jb() {
    if [ "${1-}" = "true" ]; then _HALOW_STATE_J+="true"; else _HALOW_STATE_J+="false"; fi
}
# nullable string: "" -> null
_halow_state_jqn() {
    if [ -z "${1-}" ]; then _HALOW_STATE_J+="null"; else _halow_state_jq "$1"; fi
}

# _halow_state_radio_obj <prefix:eff|last>
_halow_state_radio_obj() {
    local p="$1"
    if [ "${_HALOW_ST[${p}_set]-0}" != "1" ]; then _HALOW_STATE_J+="null"; return 0; fi
    _HALOW_STATE_J+='{"frequency_khz":'; _halow_state_jn "${_HALOW_ST[${p}_freq]-}"
    _HALOW_STATE_J+=',"channel":'; _halow_state_jn "${_HALOW_ST[${p}_channel]-}"
    _HALOW_STATE_J+=',"bandwidth_mhz":'; _halow_state_jn "${_HALOW_ST[${p}_bw]-}"
    _HALOW_STATE_J+=',"source":'; _halow_state_jq "${_HALOW_ST[${p}_source]-}"
    _HALOW_STATE_J+=',"applied_at":'; _halow_state_jn "${_HALOW_ST[${p}_applied_at]-}"
    _HALOW_STATE_J+=',"validation":'; _halow_state_jq "${_HALOW_ST[${p}_validation]-}"
    _HALOW_STATE_J+=',"fallback_validated":'
    case "${_HALOW_ST[${p}_fbv]-none}" in
        true) _HALOW_STATE_J+="true" ;;
        false) _HALOW_STATE_J+="false" ;;
        *) _HALOW_STATE_J+="null" ;;
    esac
    _HALOW_STATE_J+='}'
}

# _halow_state_render — the whole snapshot into _HALOW_STATE_J.
_halow_state_render() {
    _halow_state_ensure
    local k i first
    _HALOW_STATE_J='{"schema":2'
    _HALOW_STATE_J+=',"updated_at":'; _halow_state_jn "${_HALOW_ST[updated_at]-}"
    _HALOW_STATE_J+=',"started_at":'; _halow_state_jn "${_HALOW_ST[started_at]-}"
    _HALOW_STATE_J+=',"boot_id":'; _halow_state_jq "${_HALOW_ST[boot_id]-}"
    _HALOW_STATE_J+=',"overall":'; _halow_state_jq "${_HALOW_ST[overall]-starting}"
    _HALOW_STATE_J+=',"attention":'
    if [ "${_HALOW_ST[att_set]-0}" = "1" ]; then
        _HALOW_STATE_J+='{"code":'; _halow_state_jq "${_HALOW_ST[att_code]-}"
        _HALOW_STATE_J+=',"summary":'; _halow_state_jq "${_HALOW_ST[att_summary]-}"
        _HALOW_STATE_J+=',"action":'; _halow_state_jq "${_HALOW_ST[att_action]-}"
        _HALOW_STATE_J+=',"detail":'; _halow_state_jq "${_HALOW_ST[att_detail]-}"
        _HALOW_STATE_J+=',"since":'; _halow_state_jn "${_HALOW_ST[att_since]-}"
        _HALOW_STATE_J+=',"host_clean":'; _halow_state_jb "${_HALOW_ST[att_host_clean]-false}"
        _HALOW_STATE_J+=',"retryable":'; _halow_state_jb "${_HALOW_ST[att_retryable]-false}"
        _HALOW_STATE_J+='}'
    else
        _HALOW_STATE_J+="null"
    fi
    _HALOW_STATE_J+=',"advisory":'
    if [ "${_HALOW_ST[adv_set]-0}" = "1" ]; then
        _HALOW_STATE_J+='{"code":'; _halow_state_jq "${_HALOW_ST[adv_code]-}"
        _HALOW_STATE_J+=',"summary":'; _halow_state_jq "${_HALOW_ST[adv_summary]-}"
        _HALOW_STATE_J+=',"action":'; _halow_state_jq "${_HALOW_ST[adv_action]-}"
        _HALOW_STATE_J+=',"since":'; _halow_state_jn "${_HALOW_ST[adv_since]-}"
        _HALOW_STATE_J+='}'
    else
        _HALOW_STATE_J+="null"
    fi
    _HALOW_STATE_J+=',"region":'; _halow_state_jq "${_HALOW_ST[region]-}"
    _HALOW_STATE_J+=',"radio":{"mode":'; _halow_state_jq "${_HALOW_ST[radio_mode]-}"
    _HALOW_STATE_J+=',"requested":{"bandwidth_mhz":'; _halow_state_jn "${_HALOW_ST[req_bw]-}"
    _HALOW_STATE_J+=',"channel":'; _halow_state_jn "${_HALOW_ST[req_channel]-}"
    _HALOW_STATE_J+='},"effective":'; _halow_state_radio_obj eff
    _HALOW_STATE_J+=',"last_applied":'; _halow_state_radio_obj last
    _HALOW_STATE_J+='},"adapter":{"present":'; _halow_state_jb "${_HALOW_ST[adapter_present]-false}"
    _HALOW_STATE_J+=',"interface":'; _halow_state_jq "${_HALOW_ST[adapter_iface]-}"
    _HALOW_STATE_J+='},"backend":{"applied":'; _halow_state_jb "${_HALOW_ST[backend_applied]-false}"
    _HALOW_STATE_J+=',"bridge":'; _halow_state_jq "${_HALOW_ST[backend_bridge]-}"
    _HALOW_STATE_J+=',"subnet":'; _halow_state_jq "${_HALOW_ST[backend_subnet]-}"
    _HALOW_STATE_J+=',"gateway":'; _halow_state_jq "${_HALOW_ST[backend_gateway]-}"
    _HALOW_STATE_J+='},"stations":'"${_HALOW_ST_STATIONS_JSON:-[]}"
    _HALOW_STATE_J+=',"diagnostics":{'
    first=1
    for k in "${_HALOW_ST_DIAG_KEYS[@]}"; do
        if (( first )); then first=0; else _HALOW_STATE_J+=','; fi
        _halow_state_jq "$k"
        _HALOW_STATE_J+=':'
        _halow_state_jq "${_HALOW_ST_DIAG[$k]-}"
    done
    if (( first )); then first=0; else _HALOW_STATE_J+=','; fi
    _HALOW_STATE_J+='"log_tail":['
    for (( i = 0; i < ${#_HALOW_ST_LOG[@]}; i++ )); do
        if (( i > 0 )); then _HALOW_STATE_J+=','; fi
        _halow_state_jq "${_HALOW_ST_LOG[$i]}"
    done
    _HALOW_STATE_J+=']}}'
}

# Flush from a setter: a write failure is reported but does not fail the setter.
_halow_state_autoflush() {
    if ! halow_state_flush; then
        printf '%s\n' "halow state: the status snapshot could not be written" >&2
    fi
    return 0
}

# ---------------------------------------------------------------------------------------
# Public functions
# ---------------------------------------------------------------------------------------

# halow_state_init — create HALOW_RUN_DIR, reset every value to the starting state
# (started_at = now, boot id read from the kernel) and flush.
halow_state_init() {
    local run_dir="${HALOW_RUN_DIR:-/run/halow}" file dir
    file="$(_halow_state_file)"
    dir="${file%/*}"
    if [ "$dir" = "$file" ]; then dir="."; fi
    if ! mkdir -p -- "$run_dir" "$dir"; then
        printf '%s\n' "halow state: cannot create $run_dir" >&2
        return 1
    fi
    # The unprivileged status service must be able to traverse to the snapshot (no listing).
    chmod go+x -- "$run_dir" "$dir" 2>/dev/null || :
    # Temporary files left by an interrupted earlier writer.
    rm -f -- "$dir"/.status.json.?????? 2>/dev/null || :
    _halow_state_defaults
    _halow_state_read_boot_id
    halow_state_flush
}

# halow_state_flush — write the snapshot atomically (temporary file in the same directory,
# mode 0644, then rename). Refreshes updated_at. 0 written; 1 not written.
halow_state_flush() {
    _halow_state_ensure
    _halow_state_now
    _HALOW_ST[updated_at]="$_HALOW_STATE_NOW"
    _halow_state_render
    local file dir tmp
    file="$(_halow_state_file)"
    dir="${file%/*}"
    if [ "$dir" = "$file" ]; then dir="."; fi
    if ! mkdir -p -- "$dir" 2>/dev/null; then
        printf '%s\n' "halow state: cannot create $dir" >&2
        return 1
    fi
    if ! tmp="$(mktemp "$dir/.status.json.XXXXXX" 2>/dev/null)"; then
        printf '%s\n' "halow state: cannot create a temporary file in $dir" >&2
        return 1
    fi
    if ! printf '%s\n' "$_HALOW_STATE_J" > "$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    if ! chmod 0644 -- "$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    if ! mv -f -- "$tmp" "$file"; then
        rm -f -- "$tmp"
        return 1
    fi
    return 0
}

# halow_state_heartbeat — update updated_at and flush.
halow_state_heartbeat() {
    halow_state_flush
}

# halow_state_overall <starting|operating|attention>
# starting/operating also remove an attention entry (an entry exists only while the state
# is attention); operating additionally ends the incident, so the next attention entry
# gets a new "since" even if it has the same code.
halow_state_overall() {
    local v="${1:-}"
    case "$v" in
        starting|operating|attention) ;;
        *) return 1 ;;
    esac
    _halow_state_ensure
    _HALOW_ST[overall]="$v"
    if [ "$v" != "attention" ]; then
        _HALOW_ST[att_set]=0
    fi
    if [ "$v" = "operating" ]; then
        _HALOW_ST[att_last_code]=""
        _HALOW_ST[att_last_since]=""
    fi
    _halow_state_autoflush
}

# halow_state_attention <CODE> <detail> <host_clean:true|false>
# Sets overall=attention with the catalogue's summary, action and retryable flag. "since"
# is recorded the first time a code is set and kept while the same code is set again
# (including across retry attempts) until the access point reaches operating. An unknown
# or advisory code is recorded as INTERNAL_ERROR naming the code in the detail. A
# host_clean other than "true" is recorded as false (uncertain counts as not clean).
halow_state_attention() {
    local code="${1:-}" detail="${2-}" host_clean="${3:-false}"
    _halow_state_ensure
    if ! halow_error_known "$code" || halow_error_is_advisory "$code"; then
        _halow_state_clean "$code"
        detail="unrecognised error code '${_HALOW_REDACT_OUT}': ${detail}"
        code="INTERNAL_ERROR"
    fi
    [ "$host_clean" = "true" ] || host_clean="false"
    _halow_state_now
    if [ "${_HALOW_ST[att_last_code]-}" != "$code" ] || [ -z "${_HALOW_ST[att_last_since]-}" ]; then
        _HALOW_ST[att_last_code]="$code"
        _HALOW_ST[att_last_since]="$_HALOW_STATE_NOW"
    fi
    _HALOW_ST[att_set]=1
    _HALOW_ST[att_code]="$code"
    _HALOW_ST[att_summary]="${_HALOW_ERR_SUMMARY[$code]-}"
    _HALOW_ST[att_action]="${_HALOW_ERR_ACTION[$code]-}"
    _halow_state_clean "$detail"
    _HALOW_ST[att_detail]="$_HALOW_REDACT_OUT"
    _HALOW_ST[att_since]="${_HALOW_ST[att_last_since]}"
    _HALOW_ST[att_host_clean]="$host_clean"
    if halow_error_retryable "$code"; then
        _HALOW_ST[att_retryable]=true
    else
        _HALOW_ST[att_retryable]=false
    fi
    _HALOW_ST[overall]="attention"
    _halow_state_autoflush
}

# halow_state_clear_attention — remove the attention entry; an overall state of attention
# becomes starting (the manager sets operating when the access point is up again).
halow_state_clear_attention() {
    _halow_state_ensure
    _HALOW_ST[att_set]=0
    if [ "${_HALOW_ST[overall]-}" = "attention" ]; then
        _HALOW_ST[overall]="starting"
    fi
    _halow_state_autoflush
}

# halow_state_advisory <CODE> — set an advisory (never changes overall). "since" is kept
# while the same advisory is set again. 1 if CODE is not an advisory code.
halow_state_advisory() {
    local code="${1:-}"
    halow_error_is_advisory "$code" || return 1
    _halow_state_ensure
    if [ "${_HALOW_ST[adv_set]-0}" != "1" ] || [ "${_HALOW_ST[adv_code]-}" != "$code" ]; then
        _halow_state_now
        _HALOW_ST[adv_since]="$_HALOW_STATE_NOW"
    fi
    _HALOW_ST[adv_set]=1
    _HALOW_ST[adv_code]="$code"
    _HALOW_ST[adv_summary]="${_HALOW_ERR_SUMMARY[$code]-}"
    _HALOW_ST[adv_action]="${_HALOW_ERR_ACTION[$code]-}"
    _halow_state_autoflush
}

halow_state_clear_advisory() {
    _halow_state_ensure
    _HALOW_ST[adv_set]=0
    _HALOW_ST[adv_since]=""
    _halow_state_autoflush
}

# halow_state_region <region>
halow_state_region() {
    _halow_state_ensure
    _halow_state_clean "${1-}"
    _HALOW_ST[region]="$_HALOW_REDACT_OUT"
    _halow_state_autoflush
}

# halow_state_radio_requested <automatic|manual> <bandwidth_mhz> <channel-or-empty>
# In automatic mode a channel is ignored (recorded as null).
halow_state_radio_requested() {
    local mode="${1:-}" bw="${2-}" ch="${3-}"
    case "$mode" in automatic|manual) ;; *) return 1 ;; esac
    [[ $bw =~ ^[0-9]+$ ]] || bw=""
    [[ $ch =~ ^[0-9]+$ ]] || ch=""
    if [ "$mode" = "automatic" ]; then ch=""; fi
    _halow_state_ensure
    _HALOW_ST[radio_mode]="$mode"
    _HALOW_ST[req_bw]="$bw"
    _HALOW_ST[req_channel]="$ch"
    _halow_state_autoflush
}

# halow_state_radio_effective <frequency_khz> <channel> <bandwidth_mhz>
#     <source:acs|manual|fallback> <validation:implemented|live-validated>
#     <fallback_validated:true|false|none>
# Records the values read from the running access point; applied_at = now.
halow_state_radio_effective() {
    local freq="${1-}" ch="${2-}" bw="${3-}" src="${4:-}" val="${5:-}" fbv="${6:-none}"
    case "$src" in acs|manual|fallback) ;; *) return 1 ;; esac
    case "$val" in implemented|live-validated) ;; *) return 1 ;; esac
    case "$fbv" in true|false|none) ;; *) return 1 ;; esac
    [[ $freq =~ ^[0-9]+$ ]] || freq=""
    [[ $ch =~ ^[0-9]+$ ]] || ch=""
    [[ $bw =~ ^[0-9]+$ ]] || bw=""
    _halow_state_ensure
    _halow_state_now
    _HALOW_ST[eff_set]=1
    _HALOW_ST[eff_freq]="$freq"
    _HALOW_ST[eff_channel]="$ch"
    _HALOW_ST[eff_bw]="$bw"
    _HALOW_ST[eff_source]="$src"
    _HALOW_ST[eff_validation]="$val"
    _HALOW_ST[eff_fbv]="$fbv"
    _HALOW_ST[eff_applied_at]="$_HALOW_STATE_NOW"
    _halow_state_autoflush
}

# halow_state_radio_clear_effective — the access point is down: the effective values move
# to last_applied (keeping when they were applied) and effective becomes null.
halow_state_radio_clear_effective() {
    local f
    _halow_state_ensure
    if [ "${_HALOW_ST[eff_set]-0}" = "1" ]; then
        for f in freq channel bw source validation fbv applied_at; do
            _HALOW_ST[last_$f]="${_HALOW_ST[eff_$f]-}"
        done
        _HALOW_ST[last_set]=1
    fi
    _HALOW_ST[eff_set]=0
    _halow_state_autoflush
}

# halow_state_adapter <present:true|false> <interface-or-empty>
halow_state_adapter() {
    local present="${1:-}"
    case "$present" in true|false) ;; *) return 1 ;; esac
    _halow_state_ensure
    _HALOW_ST[adapter_present]="$present"
    _halow_state_clean "${2-}"
    _HALOW_ST[adapter_iface]="$_HALOW_REDACT_OUT"
    _halow_state_autoflush
}

# halow_state_backend <applied:true|false> <bridge> <subnet> <gateway>
halow_state_backend() {
    local applied="${1:-}"
    case "$applied" in true|false) ;; *) return 1 ;; esac
    _halow_state_ensure
    _HALOW_ST[backend_applied]="$applied"
    _halow_state_clean "${2-}"; _HALOW_ST[backend_bridge]="$_HALOW_REDACT_OUT"
    _halow_state_clean "${3-}"; _HALOW_ST[backend_subnet]="$_HALOW_REDACT_OUT"
    _halow_state_clean "${4-}"; _HALOW_ST[backend_gateway]="$_HALOW_REDACT_OUT"
    _halow_state_autoflush
}

# _halow_state_valid_mac <mac> — 0 for a colon-separated, six-octet MAC (case-insensitive).
_halow_state_valid_mac() { [[ "${1-}" =~ ^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$ ]]; }

# _halow_state_valid_ipv4 <ip> — 0 for a dotted-quad IPv4 address (octets 0-255, no leading
# zeros).
_halow_state_valid_ipv4() {
    local ip="${1-}" a b c d
    [[ $ip =~ ^(0|[1-9][0-9]{0,2})(\.(0|[1-9][0-9]{0,2})){3}$ ]] || return 1
    IFS=. read -r a b c d <<< "$ip"
    (( a <= 255 && b <= 255 && c <= 255 && d <= 255 ))
}

# _halow_state_ip_item <target-var> <count-var> <ip> <source> <conflict>
# Append one address object to the comma-separated JSON list held in <target-var> unless
# the address is invalid (not IPv4, unknown source) or the list is full
# (HALOW_STATE_IPS_MAX). <count-var> counts the items.
_halow_state_ip_item() {
    local -n _t="$1" _c="$2"
    local ip="${3-}" src="${4-}" conflict="${5-}"
    _halow_state_valid_ipv4 "$ip" || return 0
    case "$src" in dhcp|neighbour|dhcp+neighbour) ;; *) return 0 ;; esac
    (( _c < HALOW_STATE_IPS_MAX )) || return 0
    if (( _c > 0 )); then _t+=','; fi
    _t+="{\"ip\":\"${ip}\",\"source\":\"${src}\",\"conflict\":"
    if [ "$conflict" = "1" ]; then _t+="true}"; else _t+="false}"; fi
    _c=$((_c + 1))
}

# halow_state_stations_set <file> — replace the station list from a file of records, as
# printed by halow_stations_snapshot_lines (stations.sh):
#   S|mac|online(true/false)|kind(ordinary|wds)|connected_since_epoch-or-empty|changed_at_epoch|devices_omitted|online_source(hostapd|log)
#   SI|ip|source(dhcp|neighbour|dhcp+neighbour)|conflict(0|1)   an address of the station's own MAC
#   D|mac                                                       a device behind the last station
#   DI|ip|source|conflict                                       an address of the last device
# Every MAC and IP is validated here (a record with an invalid MAC is skipped together with
# the records that follow it up to the next S; an invalid address is dropped): only
# well-formed values ever reach the JSON, whatever the caller passed. online other than
# "true" is false; online_source other than "hostapd" is "log" (the online state came from
# the connection log, not from hostapd's authorised flag); an unknown kind is "ordinary"; an
# empty or invalid time is null. 1 (list
# unchanged) if the file is unreadable. Bounds: HALOW_STATE_STATIONS_MAX stations,
# HALOW_STATE_DEVICES_MAX devices in all, HALOW_STATE_DEVICES_PER_STATION_MAX per station,
# HALOW_STATE_IPS_MAX addresses per MAC; devices left out are counted in devices_omitted.
halow_state_stations_set() {
    local file="${1:-}" line tag f1 f2 f3 f4 f5 f6 f7 rest j="[" count=0 total_devs=0
    local st_open=0 skip=0 st_head="" st_ips="" st_ips_n=0 st_devs="" st_devs_n=0 st_omit=0
    local dev_open=0 dev_head="" dev_ips="" dev_ips_n=0
    if [ -z "$file" ] || [ ! -r "$file" ] || [ -d "$file" ]; then return 1; fi
    _halow_state_ensure

    _halow_state_close_dev() {
        if (( dev_open )); then
            (( st_devs_n == 0 )) || st_devs+=','
            st_devs+="${dev_head}${dev_ips}]}"
            st_devs_n=$((st_devs_n + 1))
        fi
        dev_open=0; dev_head=""; dev_ips=""; dev_ips_n=0
    }
    _halow_state_close_st() {
        _halow_state_close_dev
        if (( st_open )); then
            (( count == 0 )) || j+=','
            j+="${st_head}\"ips\":[${st_ips}],\"devices\":[${st_devs}],\"devices_omitted\":${st_omit}}"
            count=$((count + 1))
        fi
        st_open=0; st_head=""; st_ips=""; st_ips_n=0; st_devs=""; st_devs_n=0; st_omit=0
    }

    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        [ -n "$line" ] || continue
        IFS='|' read -r tag f1 f2 f3 f4 f5 f6 f7 rest <<< "$line"
        case "$tag" in
            S)
                _halow_state_close_st
                skip=1
                _halow_state_valid_mac "$f1" || continue
                (( count < HALOW_STATE_STATIONS_MAX )) || break
                skip=0; st_open=1
                case "$f3" in ordinary|wds) ;; *) f3="ordinary" ;; esac
                _HALOW_STATE_J=""
                _HALOW_STATE_J+='{"mac":"'"${f1,,}"'","online":'; _halow_state_jb "$f2"
                case "$f7" in hostapd) ;; *) f7="log" ;; esac
                _HALOW_STATE_J+=',"online_source":"'"$f7"'"'
                _HALOW_STATE_J+=',"kind":"'"$f3"'","connected_since":'; _halow_state_jn "$f4"
                _HALOW_STATE_J+=',"state_changed_at":'; _halow_state_jn "$f5"
                _HALOW_STATE_J+=','
                st_head="$_HALOW_STATE_J"
                [[ $f6 =~ ^[0-9]{1,6}$ ]] && st_omit=$((10#$f6)) || st_omit=0
                ;;
            SI)
                (( skip == 0 && st_open == 1 && dev_open == 0 )) || continue
                _halow_state_ip_item st_ips st_ips_n "$f1" "$f2" "$f3"
                ;;
            D)
                (( skip == 0 && st_open == 1 )) || continue
                _halow_state_close_dev
                _halow_state_valid_mac "$f1" || continue
                if (( st_devs_n >= HALOW_STATE_DEVICES_PER_STATION_MAX || total_devs >= HALOW_STATE_DEVICES_MAX )); then
                    st_omit=$((st_omit + 1)); continue
                fi
                total_devs=$((total_devs + 1))
                dev_open=1; dev_ips=""; dev_ips_n=0
                dev_head="{\"mac\":\"${f1,,}\",\"ips\":["
                ;;
            DI)
                (( skip == 0 && dev_open == 1 )) || continue
                _halow_state_ip_item dev_ips dev_ips_n "$f1" "$f2" "$f3"
                ;;
            *) ;;
        esac
    done < "$file"
    _halow_state_close_st
    unset -f _halow_state_close_dev _halow_state_close_st
    j+="]"
    _HALOW_ST_STATIONS_JSON="$j"
    _halow_state_autoflush
}

# halow_state_diag_set <key> <value> — diagnostics-only string entry (value redacted and
# escaped). Key: letters, digits, '_', '.', '-' (not "log_tail"). Not flushed by itself.
halow_state_diag_set() {
    local key="${1:-}"
    if [[ ! $key =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || [ "$key" = "log_tail" ]; then return 1; fi
    _halow_state_ensure
    if [ -z "${_HALOW_ST_DIAG[$key]+x}" ]; then
        if (( ${#_HALOW_ST_DIAG_KEYS[@]} >= HALOW_STATE_DIAG_MAX )); then return 1; fi
        _HALOW_ST_DIAG_KEYS+=("$key")
    fi
    _halow_state_clean "${2-}"
    _HALOW_ST_DIAG[$key]="$_HALOW_REDACT_OUT"
    return 0
}

# halow_state_diag_log_append <line> — redacted line appended to the bounded log tail
# (HALOW_STATE_LOG_MAX lines, default 200; each line cut to HALOW_STATE_LOG_LINE_MAX
# bytes). Not flushed by itself.
halow_state_diag_log_append() {
    local line="${1-}" max="${HALOW_STATE_LOG_MAX:-200}"
    _halow_state_ensure
    _halow_state_clean "$line"
    line="$_HALOW_REDACT_OUT"
    if (( ${#line} > HALOW_STATE_LOG_LINE_MAX )); then line="${line:0:HALOW_STATE_LOG_LINE_MAX}"; fi
    _HALOW_ST_LOG+=("$line")
    while (( ${#_HALOW_ST_LOG[@]} > max )); do
        _HALOW_ST_LOG=("${_HALOW_ST_LOG[@]:1}")
    done
    return 0
}

# halow_state_diag_unset <key> - removes one diagnostics entry (no error when absent).
# Not flushed by itself.
halow_state_diag_unset() {
    local key="${1:-}" k
    local -a keep=()
    _halow_state_ensure
    [ -n "${_HALOW_ST_DIAG[$key]+x}" ] || return 0
    unset "_HALOW_ST_DIAG[$key]"
    for k in "${_HALOW_ST_DIAG_KEYS[@]}"; do
        [ "$k" = "$key" ] || keep+=("$k")
    done
    _HALOW_ST_DIAG_KEYS=("${keep[@]+"${keep[@]}"}")
    return 0
}
