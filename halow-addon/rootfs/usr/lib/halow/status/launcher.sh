#!/usr/bin/env bash
# halow: launcher of the unprivileged status service (sourced by the s6 `run` script of
# the status service). Defines functions only; never runs anything when sourced.
#
# The launcher runs as root only long enough to prepare the start, then starts the Python
# server as HALOW_STATUS_USER through s6-setuidgid. In order it:
#   1. waits (bounded) for the manager's ready file HALOW_RUN_READY_FILE: the manager
#      mounts a memory-backed filesystem on HALOW_RUN_DIR first and creates the file
#      afterwards, so nothing written before it exists could be hidden by the mount. The
#      launcher writes nothing under the run directory before the file exists;
#   2. reads the Ingress port (never guessed);
#   3. checks that the status user exists and the server program is present;
#   4. verifies, as the status user, that the user cannot read any token file of the
#      container environment (HALOW_S6_CONTAINER_ENV_DIR). If one is readable, or the
#      check itself cannot be made, the server is not started;
#   5. prepares the dedicated liveness directory (owned by the status user, mode 0700, and
#      emptied of any earlier counter file): the only place the status user can write;
#   6. writes the listening port to HALOW_STATUS_PORT_FILE (mode 0644) for the manager's
#      liveness check;
#   7. removes the Supervisor token from its own environment and execs the server.
# Any refusal logs an error and returns non-zero after a short pause, so s6 tries again.
#
# The child gets the port, the bind address, the allowed peer, the snapshot path, the
# stale threshold and the liveness counter path, never the Supervisor token.
#
# Every external command is called by name (fakeable on PATH); the Python interpreter and
# the server script are selectable through HALOW_STATUS_PYTHON and HALOW_STATUS_SERVER.

: "${HALOW_STATUS_RUN_WAIT_S:=30}"
: "${HALOW_STATUS_RETRY_SLEEP_S:=5}"
: "${HALOW_S6_CONTAINER_ENV_DIR:=/run/s6/container_environment}"

_halow_status_log() { # _halow_status_log <info|warning|error> <message>
    local level="$1" msg="$2"
    case "$level" in
        info) if declare -F bashio::log.info >/dev/null; then bashio::log.info "$msg"; return 0; fi ;;
        warning) if declare -F bashio::log.warning >/dev/null; then bashio::log.warning "$msg"; return 0; fi ;;
        *) if declare -F bashio::log.error >/dev/null; then bashio::log.error "$msg"; return 0; fi ;;
    esac
    printf '%s\n' "status service: $msg" >&2
}

# halow_status_ingress_port — prints the Ingress port; 1 if it cannot be determined.
# HALOW_STATUS_PORT (environment) takes precedence (tests); otherwise bashio is asked.
halow_status_ingress_port() {
    local port="${HALOW_STATUS_PORT:-}"
    if [ -z "$port" ]; then
        if declare -F bashio::app.ingress_port >/dev/null; then
            port="$(bashio::app.ingress_port 2>/dev/null)" || port=""
        elif declare -F bashio::addon.ingress_port >/dev/null; then
            port="$(bashio::addon.ingress_port 2>/dev/null)" || port=""
        fi
    fi
    if [[ ! $port =~ ^[0-9]{1,5}$ ]] || (( 10#$port < 1 || 10#$port > 65535 )); then
        return 1
    fi
    printf '%s\n' "$((10#$port))"
}

# halow_status_wait_ready — waits (bounded by HALOW_STATUS_RUN_WAIT_S) for the manager's
# ready file; 0 present, 1 timed out.
halow_status_wait_ready() {
    local ready="${HALOW_RUN_READY_FILE:-${HALOW_RUN_DIR:-/run/halow}/.ready}" waited=0
    while [ ! -e "$ready" ]; do
        if (( waited >= HALOW_STATUS_RUN_WAIT_S )); then return 1; fi
        sleep 1
        waited=$((waited + 1))
    done
    return 0
}

# halow_status_tokens_private <user> — verifies, by trying to read them as <user>, that
# no token file of the container environment (every regular file in
# HALOW_S6_CONTAINER_ENV_DIR whose name contains TOKEN) is readable by that user.
# 0 none readable (or no such directory); 1 a token file is readable (its name is in
# HALOW_STATUS_TOKEN_READABLE); 2 the check could not be made (the user cannot run a
# command at all). Never prints a token.
halow_status_tokens_private() {
    local user="$1" dir="${HALOW_S6_CONTAINER_ENV_DIR}" f
    HALOW_STATUS_TOKEN_READABLE=""
    [ -d "$dir" ] || return 0
    # Positive control: a probe that fails for every file must not count as "private".
    if ! s6-setuidgid "$user" true >/dev/null 2>&1; then
        return 2
    fi
    for f in "$dir"/*TOKEN*; do
        [ -f "$f" ] || continue
        if s6-setuidgid "$user" cat -- "$f" >/dev/null 2>&1; then
            HALOW_STATUS_TOKEN_READABLE="${f##*/}"
            return 1
        fi
    done
    return 0
}

# halow_status_write_port <port> — writes the port to HALOW_STATUS_PORT_FILE (temporary
# file, mode 0644, rename). 0 written; 1 not written.
halow_status_write_port() {
    local file="${HALOW_STATUS_PORT_FILE:-${HALOW_RUN_DIR:-/run/halow}/status.port}" tmp
    tmp="${file}.tmp.$$"
    if ! printf '%s\n' "$1" > "$tmp" 2>/dev/null || ! chmod 0644 -- "$tmp" 2>/dev/null \
       || ! mv -f -- "$tmp" "$file" 2>/dev/null; then
        rm -f -- "$tmp" 2>/dev/null || :
        return 1
    fi
    return 0
}

# halow_status_heartbeat_file — prints the path of the status server's liveness counter:
# always /run/halow-status/heartbeat. HALOW_STATUS_HEARTBEAT_FILE changes it only when
# HALOW_STATUS_TEST_MODE=1 (the off-device tests); production never honours it.
halow_status_heartbeat_file() {
    if [ "${HALOW_STATUS_TEST_MODE:-0}" = "1" ] && [ -n "${HALOW_STATUS_HEARTBEAT_FILE:-}" ]; then
        printf '%s\n' "$HALOW_STATUS_HEARTBEAT_FILE"
    else
        printf '%s\n' "/run/halow-status/heartbeat"
    fi
}

# halow_status_prepare_heartbeat <user> — as root, before the server is started: makes the
# status service's dedicated liveness directory (the directory of the file named by
# halow_status_heartbeat_file; it is the one place the unprivileged user may write), owned
# by <user>, mode 0700, and empty. An earlier life of the server may have left anything in
# it (a stale counter, a directory, a FIFO, a link); the directory is removed with rm -rf
# (which never follows a link) and made again, so nothing of it survives and nothing can
# keep the service from starting. Only a directory named halow-status and a file named
# heartbeat are accepted (in production exactly /run/halow-status/heartbeat), never /, /run,
# /tmp or the run directory, and a link or a non-directory at the directory path is refused.
# Owner and mode are checked again after they are set. 0 prepared; 1 not prepared.
halow_status_prepare_heartbeat() {
    local user="$1" file dir uid gid
    file="$(halow_status_heartbeat_file)"
    dir="${file%/*}"
    case "$dir" in
        ''|/|/run|/tmp|"${HALOW_RUN_DIR:-/run/halow}") return 1 ;;
    esac
    [ "${dir##*/}" = "halow-status" ] && [ "${file##*/}" = "heartbeat" ] || return 1
    uid="$(id -u "$user" 2>/dev/null)" || return 1
    gid="$(id -g "$user" 2>/dev/null)" || return 1
    [[ $uid =~ ^[0-9]+$ && $gid =~ ^[0-9]+$ ]] || return 1
    if [ -L "$dir" ] || { [ -e "$dir" ] && [ ! -d "$dir" ]; }; then return 1; fi
    rm -rf -- "$dir" 2>/dev/null || return 1
    mkdir -p -- "$dir" 2>/dev/null || return 1
    chown "$uid:$gid" -- "$dir" 2>/dev/null || return 1
    chmod 0700 -- "$dir" 2>/dev/null || return 1
    [ "$(stat -c '%a %u' -- "$dir" 2>/dev/null)" = "700 $uid" ] || return 1
    [ -z "$(ls -A -- "$dir" 2>/dev/null)" ] || return 1
    return 0
}

# halow_status_launcher_main — wait for the ready file, read the port, verify the token
# files are private to root, record the port, drop privileges and exec the server.
# Returns (non-zero) only when the server is not started.
halow_status_launcher_main() {
    local port user="${HALOW_STATUS_USER:-halowstatus}" rc
    local python="${HALOW_STATUS_PYTHON:-python3}"
    local server="${HALOW_STATUS_SERVER:-${HALOW_LIB_DIR:-/usr/lib/halow}/status/status_server.py}"
    if ! halow_status_wait_ready; then
        _halow_status_log error "the run directory is not ready yet (the manager has not prepared it); the status service is started again shortly"
        sleep "$HALOW_STATUS_RETRY_SLEEP_S"
        return 1
    fi
    if ! port="$(halow_status_ingress_port)"; then
        _halow_status_log error "the Ingress port could not be read; the status page is unavailable until the next attempt"
        sleep "$HALOW_STATUS_RETRY_SLEEP_S"
        return 1
    fi
    if ! id -u "$user" >/dev/null 2>&1; then
        _halow_status_log error "the unprivileged user '$user' does not exist; the status service is not started"
        sleep "$HALOW_STATUS_RETRY_SLEEP_S"
        return 1
    fi
    if [ ! -r "$server" ]; then
        _halow_status_log error "the status server program is missing; the status service is not started"
        sleep "$HALOW_STATUS_RETRY_SLEEP_S"
        return 1
    fi
    if halow_status_tokens_private "$user"; then rc=0; else rc=$?; fi
    if [ "$rc" -eq 1 ]; then
        _halow_status_log error "the container environment file ${HALOW_STATUS_TOKEN_READABLE} is readable by the unprivileged user '$user'; refusing to start the status service"
        sleep "$HALOW_STATUS_RETRY_SLEEP_S"
        return 1
    elif [ "$rc" -ne 0 ]; then
        _halow_status_log error "could not verify that the unprivileged user '$user' cannot read the Supervisor token; refusing to start the status service"
        sleep "$HALOW_STATUS_RETRY_SLEEP_S"
        return 1
    fi
    if ! halow_status_prepare_heartbeat "$user"; then
        _halow_status_log error "the liveness directory could not be prepared; the status service is not started"
        sleep "$HALOW_STATUS_RETRY_SLEEP_S"
        return 1
    fi
    if ! halow_status_write_port "$port"; then
        _halow_status_log error "the listening port could not be recorded for the liveness check; the status service is not started"
        sleep "$HALOW_STATUS_RETRY_SLEEP_S"
        return 1
    fi
    # The child never receives the Supervisor token.
    unset SUPERVISOR_TOKEN HASSIO_TOKEN
    _halow_status_log info "starting the status service on port ${port}"
    exec s6-setuidgid "$user" "$python" "$server" \
        --port "$port" \
        --bind "${HALOW_STATUS_BIND:-172.30.32.1}" \
        --allow-from "${HALOW_STATUS_ALLOW_FROM:-172.30.32.2}" \
        --snapshot "${HALOW_STATUS_FILE:-${HALOW_RUN_DIR:-/run/halow}/status.json}" \
        --stale-after "${HALOW_STATUS_STALE_AFTER_S:-90}" \
        --heartbeat-file "$(halow_status_heartbeat_file)"
}
