#!/usr/bin/env bash
# halow: the closed error catalogue shown on the status page and in the snapshot.
#
# Every condition the manager can report is one of the codes below. Each code has plain
# customer wording (summary), a concrete next step (action) and a retry class. The one
# advisory code (RADIO_AUTO_FALLBACK) describes a running access point and is never an
# attention state.
#
# Library rules: defines data and functions only, never runs anything when sourced, is
# re-sourceable (plain assignments into global associative arrays) and is safe under
# errexit/nounset/pipefail.

# Display order of the catalogue (attention codes, then the advisory).
HALOW_ERROR_CODES="NO_ADAPTER MULTIPLE_ADAPTERS UNSUPPORTED_KERNEL REGION_UNVALIDATED CONFIG_INVALID FIRMWARE_INVALID MODULE_LOAD_FAILED HOST_STATE_FAILED AP_START_FAILED AP_DIED BACKEND_FAILED NM_CHECK_FAILED UPLINK_UNAVAILABLE ROLLBACK_INCOMPLETE STATUS_STALE RADIO_MISMATCH INTERNAL_ERROR"
HALOW_ADVISORY_CODES="RADIO_AUTO_FALLBACK"

# Recoverable conditions: the manager keeps retrying by itself with backoff.
HALOW_ERROR_RETRYABLE_CODES="NO_ADAPTER MULTIPLE_ADAPTERS UPLINK_UNAVAILABLE"

declare -gA _HALOW_ERR_SUMMARY
declare -gA _HALOW_ERR_ACTION

_HALOW_ERR_SUMMARY[NO_ADAPTER]="The Morse Micro Wi-Fi HaLow USB Network Adapter was not found."
_HALOW_ERR_ACTION[NO_ADAPTER]="Plug the adapter into your Home Assistant Green. The app keeps checking and starts the access point once it finds the adapter."

_HALOW_ERR_SUMMARY[MULTIPLE_ADAPTERS]="More than one Morse Micro Wi-Fi HaLow USB Network Adapter is connected."
_HALOW_ERR_ACTION[MULTIPLE_ADAPTERS]="Leave one adapter connected and unplug the others. The access point starts automatically once only one adapter is present."

_HALOW_ERR_SUMMARY[UNSUPPORTED_KERNEL]="This version of the app does not support the Home Assistant OS version on your system."
_HALOW_ERR_ACTION[UNSUPPORTED_KERNEL]="Update the app to a version that supports your Home Assistant OS version, then restart it. Until then the Wi-Fi HaLow access point stays off, and the app does not apply new radio or network changes."

_HALOW_ERR_SUMMARY[REGION_UNVALIDATED]="The selected region is not supported by this version of the app."
_HALOW_ERR_ACTION[REGION_UNVALIDATED]="Choose a supported Region and restart the app."

_HALOW_ERR_SUMMARY[CONFIG_INVALID]="A setting has a value the app cannot use."
_HALOW_ERR_ACTION[CONFIG_INVALID]="Change the setting named in the details to a valid value, then restart the app."

_HALOW_ERR_SUMMARY[FIRMWARE_INVALID]="The adapter's firmware or driver files in the app did not pass their check."
_HALOW_ERR_ACTION[FIRMWARE_INVALID]="Update or reinstall the app, then restart it."

_HALOW_ERR_SUMMARY[MODULE_LOAD_FAILED]="The adapter's driver could not be loaded or did not start."
_HALOW_ERR_ACTION[MODULE_LOAD_FAILED]="Restart the app. If it happens again, update the app to the latest version."

_HALOW_ERR_SUMMARY[HOST_STATE_FAILED]="A system setting the app needs could not be checked or changed, so the access point did not start."
_HALOW_ERR_ACTION[HOST_STATE_FAILED]="The details name the setting. Restart the app. If the details mention IP forwarding (a system setting that lets traffic pass through), restart Home Assistant Green from the System page instead, because the app does not change it. If it happens again, update the app to the latest version."

_HALOW_ERR_SUMMARY[AP_START_FAILED]="The Wi-Fi HaLow access point could not start."
_HALOW_ERR_ACTION[AP_START_FAILED]="The app retries a few times on its own. If this message stays, check Region, Bandwidth, Channel selection mode, and Channel, then restart the app."

_HALOW_ERR_SUMMARY[AP_DIED]="The Wi-Fi HaLow access point stopped unexpectedly."
_HALOW_ERR_ACTION[AP_DIED]="The app retries a few times on its own. If this message stays, restart the app."

_HALOW_ERR_SUMMARY[BACKEND_FAILED]="The Wi-Fi HaLow network could not be set up or kept running."
_HALOW_ERR_ACTION[BACKEND_FAILED]="Check that Wi-Fi HaLow network address does not overlap another network. If the details name a port, make sure nothing else on your Home Assistant Green uses it. Then restart the app. If it happens again, update the app to the latest version."

_HALOW_ERR_SUMMARY[NM_CHECK_FAILED]="The app could not stop Home Assistant from managing the adapter and the Wi-Fi HaLow network."
_HALOW_ERR_ACTION[NM_CHECK_FAILED]="Restart the app. If it happens again, restart Home Assistant Green from the System page, then update the app to the latest version."

_HALOW_ERR_SUMMARY[UPLINK_UNAVAILABLE]="No network connection was found for your Wi-Fi HaLow devices to reach the rest of your network."
_HALOW_ERR_ACTION[UPLINK_UNAVAILABLE]="Check that your Home Assistant Green is connected to your network. If you set Uplink interface, check that it is correct. The app keeps checking and continues automatically when a connection is available."

_HALOW_ERR_SUMMARY[ROLLBACK_INCOMPLETE]="The app could not confirm that it undid all of its changes to your system, so it does not apply new radio or network changes."
_HALOW_ERR_ACTION[ROLLBACK_INCOMPLETE]="Restart Home Assistant Green from the System page to return it to a clean state. This restarts your whole Home Assistant system, not only this app."

_HALOW_ERR_SUMMARY[STATUS_STALE]="The status has not been updated recently, so what you see may be out of date."
_HALOW_ERR_ACTION[STATUS_STALE]="Restart the app. If the message stays, check the app's Log tab."

_HALOW_ERR_SUMMARY[RADIO_MISMATCH]="The access point is using radio settings that differ from your settings."
_HALOW_ERR_ACTION[RADIO_MISMATCH]="Check Region, Bandwidth, Channel selection mode, and Channel, then restart the app. If it happens again, update the app to the latest version."

_HALOW_ERR_SUMMARY[INTERNAL_ERROR]="The app ran into an unexpected problem."
_HALOW_ERR_ACTION[INTERNAL_ERROR]="Restart the app. If it happens again, update the app to the latest version and keep the diagnostics for support."

_HALOW_ERR_SUMMARY[RADIO_AUTO_FALLBACK]="Automatic channel selection did not complete, so the access point started on a backup channel."
_HALOW_ERR_ACTION[RADIO_AUTO_FALLBACK]="Wi-Fi HaLow devices can connect on the channel shown below. Restart the app to try automatic selection again, or set Channel selection mode to manual and choose a channel."

# halow_error_known <CODE> — 0 if CODE is an attention code or the advisory code.
halow_error_known() {
    local code="${1:-}"
    case "$code" in ""|*[!A-Z_]*) return 1 ;; esac
    case " $HALOW_ERROR_CODES $HALOW_ADVISORY_CODES " in
        *" $code "*) return 0 ;;
    esac
    return 1
}

# halow_error_is_advisory <CODE> — 0 if CODE is an advisory (the access point is up).
halow_error_is_advisory() {
    local code="${1:-}"
    case "$code" in ""|*[!A-Z_]*) return 1 ;; esac
    case " $HALOW_ADVISORY_CODES " in
        *" $code "*) return 0 ;;
    esac
    return 1
}

# halow_error_summary <CODE> — prints the plain summary; 1 (nothing printed) if unknown.
halow_error_summary() {
    halow_error_known "${1:-}" || return 1
    printf '%s\n' "${_HALOW_ERR_SUMMARY[$1]-}"
}

# halow_error_action <CODE> — prints the next-step text; 1 (nothing printed) if unknown.
halow_error_action() {
    halow_error_known "${1:-}" || return 1
    printf '%s\n' "${_HALOW_ERR_ACTION[$1]-}"
}

# halow_error_retryable <CODE> — 0 if the condition is recoverable (retried forever with
# backoff); 1 otherwise, including for an unknown code.
halow_error_retryable() {
    local code="${1:-}"
    halow_error_known "$code" || return 1
    case " $HALOW_ERROR_RETRYABLE_CODES " in
        *" $code "*) return 0 ;;
    esac
    return 1
}

# halow_error_list — prints every code (attention codes, then the advisory), one per line.
halow_error_list() {
    local code
    for code in $HALOW_ERROR_CODES $HALOW_ADVISORY_CODES; do
        printf '%s\n' "$code"
    done
}
