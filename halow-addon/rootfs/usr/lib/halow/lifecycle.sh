#!/usr/bin/env bash
# halow: retry policy, backoff and the manager restart counter.
#
# Retry policy for a failed start attempt (the code is the error catalogue's):
#   recoverable  NO_ADAPTER MULTIPLE_ADAPTERS UPLINK_UNAVAILABLE
#                retried with backoff and no count limit; every retry is a full start
#   bounded      AP_START_FAILED AP_DIED
#                at most HALOW_AP_RETRY_LIMIT (3) consecutive failed attempts, then the
#                manager stays in "attention required"
#   rollback     ROLLBACK_INCOMPLETE
#                only the rollback and its verification are retried (with backoff); no
#                new host change is made
#   never        everything else (configuration, compatibility, firmware, module, host
#                state, backend, NetworkManager, radio mismatch, internal errors): the
#                action text tells the customer to change an option and restart the
#                add-on, or to update it
#
# The restart counter counts exits of the manager service (kept by its finish hook). It
# lives in the volatile run directory so that recreating the container resets it; a
# counter on the persistent volume would survive and could halt the add-on forever.
#
# Defines functions and constants only.

: "${HALOW_AP_RETRY_LIMIT:=3}"
: "${HALOW_BACKOFF_FIRST_S:=5}"
: "${HALOW_BACKOFF_CAP_S:=120}"
# finish halts the container after this many manager exits within the window.
: "${HALOW_MANAGER_EXIT_LIMIT:=5}"
: "${HALOW_MANAGER_EXIT_WINDOW_S:=600}"

HALOW_LIFECYCLE_RECOVERABLE="NO_ADAPTER MULTIPLE_ADAPTERS UPLINK_UNAVAILABLE"
HALOW_LIFECYCLE_BOUNDED="AP_START_FAILED AP_DIED"

# halow_backoff_next <attempt>
# Prints the wait in seconds before retry number <attempt> (1-based): 5, 10, 20, 40, 80,
# then 120 for every later attempt. A missing or invalid attempt counts as 1.
halow_backoff_next() {
    local attempt="${1:-1}" s
    case "$attempt" in
        ''|*[!0-9]*) attempt=1 ;;
    esac
    [ "$attempt" -ge 1 ] || attempt=1
    s="$HALOW_BACKOFF_FIRST_S"
    while [ "$attempt" -gt 1 ] && [ "$s" -lt "$HALOW_BACKOFF_CAP_S" ]; do
        s=$((s * 2))
        attempt=$((attempt - 1))
    done
    [ "$s" -le "$HALOW_BACKOFF_CAP_S" ] || s="$HALOW_BACKOFF_CAP_S"
    printf '%s' "$s"
}

# halow_lifecycle_retry_class <CODE> — prints recoverable | bounded | rollback | never.
halow_lifecycle_retry_class() {
    local code="${1:-}"
    case " $HALOW_LIFECYCLE_RECOVERABLE " in
        *" $code "*) printf 'recoverable'; return 0 ;;
    esac
    case " $HALOW_LIFECYCLE_BOUNDED " in
        *" $code "*) printf 'bounded'; return 0 ;;
    esac
    if [ "$code" = "ROLLBACK_INCOMPLETE" ]; then
        printf 'rollback'
        return 0
    fi
    printf 'never'
}

# halow_lifecycle_should_retry <CODE> <consecutive_failures>
# 0 retry (after a backoff); 1 stay in attention. <consecutive_failures> includes the
# failure just seen.
halow_lifecycle_should_retry() {
    local code="${1:-}" n="${2:-1}" class
    case "$n" in ''|*[!0-9]*) n=1 ;; esac
    class="$(halow_lifecycle_retry_class "$code")"
    case "$class" in
        recoverable|rollback) return 0 ;;
        bounded) [ "$n" -lt "$HALOW_AP_RETRY_LIMIT" ] ;;
        *) return 1 ;;
    esac
}

# --- Manager restart counter (finish hook) -----------------------------------------

halow_restart_count_file() {
    printf '%s/manager_exits' "${HALOW_RUN_DIR:?}"
}

# halow_restart_count_get [<now_epoch>]
# Prints how many manager exits were recorded within the last HALOW_MANAGER_EXIT_WINDOW_S
# seconds (all recorded exits when <now_epoch> is not given).
halow_restart_count_get() {
    local now="${1:-}" f line n=0
    f="$(halow_restart_count_file)"
    if [ -f "$f" ]; then
        while IFS= read -r line; do
            case "$line" in ''|*[!0-9]*) continue ;; esac
            if [ -n "$now" ] && [ $((now - line)) -gt "$HALOW_MANAGER_EXIT_WINDOW_S" ]; then
                continue
            fi
            n=$((n + 1))
        done < "$f"
    fi
    printf '%s' "$n"
}

# halow_restart_count_incr [<now_epoch>] — records one manager exit. 1 if it cannot.
halow_restart_count_incr() {
    local now="${1:-}" f
    [ -n "$now" ] || now="$(date +%s)"
    f="$(halow_restart_count_file)"
    mkdir -p -- "${HALOW_RUN_DIR:?}" 2>/dev/null || return 1
    printf '%s\n' "$now" >> "$f" 2>/dev/null || return 1
}

# halow_restart_count_reset — forgets every recorded exit.
halow_restart_count_reset() {
    rm -f -- "$(halow_restart_count_file)" 2>/dev/null || true
}
