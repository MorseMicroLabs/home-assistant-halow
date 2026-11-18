#!/usr/bin/env bash
# The closed error catalogue: completeness, wording for every code, retry classes, the
# advisory, and the specific next steps the page must give.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh
. ./helpers_status.sh

echo "== test_errors =="
halow_status_test_setup
trap halow_status_test_teardown EXIT

EXPECTED_CODES="NO_ADAPTER MULTIPLE_ADAPTERS UNSUPPORTED_KERNEL REGION_UNVALIDATED CONFIG_INVALID FIRMWARE_INVALID MODULE_LOAD_FAILED HOST_STATE_FAILED AP_START_FAILED AP_DIED BACKEND_FAILED NM_CHECK_FAILED UPLINK_UNAVAILABLE ROLLBACK_INCOMPLETE STATUS_STALE RADIO_MISMATCH INTERNAL_ERROR RADIO_AUTO_FALLBACK"

echo "-- the list is exactly the catalogue, in order, without duplicates --"
listed="$(halow_error_list | tr '\n' ' ')"
assert_eq "$EXPECTED_CODES " "$listed" "halow_error_list prints every code once, in catalogue order"
assert_eq "18" "$(halow_error_list | wc -l | tr -d ' ')" "18 codes (17 attention codes and the advisory)"
assert_eq "18" "$(halow_error_list | sort -u | wc -l | tr -d ' ')" "no duplicate code"

echo "-- every code has plain wording and a next step --"
for code in $EXPECTED_CODES; do
    assert_success "$code is known" halow_error_known "$code"
    s="$(halow_error_summary "$code")"; a="$(halow_error_action "$code")"
    HALOW_TEST_COUNT=$((HALOW_TEST_COUNT + 1))
    if [ "${#s}" -ge 20 ] && [ "${#a}" -ge 15 ] && [[ $s == *. ]] && [[ $a == *. ]]; then
        echo "  ok: $code has a summary and an action (full sentences)"
    else
        echo "  FAIL: $code wording missing or not a sentence (summary='$s' action='$a')"
        HALOW_TEST_FAILURES=$((HALOW_TEST_FAILURES + 1))
    fi
    # Customer wording carries no internal mechanism names.
    lower="${s,,} ${a,,}"
    HALOW_TEST_COUNT=$((HALOW_TEST_COUNT + 1))
    case "$lower" in
        *hostapd*|*dot11ah*|*iptables*|*"operating class"*|*sysfs*|*modprobe*|*insmod*|*" bcf"*|*"add-on"*|*"forwarding table"*|*neighbour*|*"development build"*|*"live-validated"*)
            echo "  FAIL: $code wording names an internal mechanism: $lower"
            HALOW_TEST_FAILURES=$((HALOW_TEST_FAILURES + 1)) ;;
        *) echo "  ok: $code wording has no internal mechanism names" ;;
    esac
    # Every use of the product name is "Wi-Fi HaLow"; a bare "HaLow" never appears.
    HALOW_TEST_COUNT=$((HALOW_TEST_COUNT + 1))
    if [ "$(sed -E 's/Wi-Fi HaLow//g' <<< "$s $a" | grep -c 'HaLow')" = 0 ]; then
        echo "  ok: $code wording never uses a bare 'HaLow'"
    else
        echo "  FAIL: $code wording uses a bare 'HaLow': $s $a"
        HALOW_TEST_FAILURES=$((HALOW_TEST_FAILURES + 1))
    fi
done

echo "-- retry classes --"
for code in $EXPECTED_CODES; do
    case "$code" in
        NO_ADAPTER|MULTIPLE_ADAPTERS|UPLINK_UNAVAILABLE)
            assert_success "$code is recoverable" halow_error_retryable "$code"
            assert_success "$code action says the app keeps checking or continues automatically" \
                bash -c '[[ "$1" == *"The app keeps checking"* || "$1" == *"automatically"* ]]' _ "$(halow_error_action "$code")" ;;
        *)
            assert_failure "$code is not recoverable" halow_error_retryable "$code" ;;
    esac
done

echo "-- configuration and compatibility errors say what to change or update --"
for code in REGION_UNVALIDATED CONFIG_INVALID; do
    a="$(halow_error_action "$code")"
    assert_success "$code action: set the option and restart the app" \
        bash -c '[[ ( "$1" == Change* || "$1" == Set* || "$1" == Choose* ) && "$1" == *"restart the app"* ]]' _ "$a"
done
assert_eq "Choose a supported Region and restart the app." "$(halow_error_action REGION_UNVALIDATED)" "REGION_UNVALIDATED action is the approved wording"
assert_success "REGION_UNVALIDATED wording does not name Australia" \
    bash -c '[[ "$1" != *Australia* ]]' _ "$(halow_error_summary REGION_UNVALIDATED) $(halow_error_action REGION_UNVALIDATED)"
for code in UNSUPPORTED_KERNEL FIRMWARE_INVALID; do
    a="$(halow_error_action "$code")"
    assert_success "$code action: update the app" bash -c '[[ "$1" == "Update "* && "$1" == *" the app"* ]]' _ "$a"
done
for code in MODULE_LOAD_FAILED HOST_STATE_FAILED NM_CHECK_FAILED RADIO_MISMATCH INTERNAL_ERROR; do
    a="$(halow_error_action "$code")"
    assert_success "$code action mentions updating the app" bash -c '[[ "$1" == *"update the app"* ]]' _ "$a"
done
for code in AP_START_FAILED RADIO_MISMATCH; do
    a="$(halow_error_action "$code")"
    assert_success "$code action names the settings by their form labels" \
        bash -c '[[ "$1" == *"Region, Bandwidth, Channel selection mode, and Channel"* ]]' _ "$a"
done
assert_success "CONFIG_INVALID points at the option named in the details" \
    bash -c '[[ "$1" == *"setting named in the details"* ]]' _ "$(halow_error_action CONFIG_INVALID)"

echo "-- wording that fits every case the code is raised for --"
s="$(halow_error_summary HOST_STATE_FAILED)"; a="$(halow_error_action HOST_STATE_FAILED)"
assert_success "HOST_STATE_FAILED summary is not limited to the firmware setting" \
    bash -c 'l="${1,,}"; [[ "$l" != *firmware* && "$l" == *"system setting"* ]]' _ "$s"
assert_success "HOST_STATE_FAILED action explains IP forwarding and that the app does not change it" \
    bash -c '[[ "$1" == *"IP forwarding (a system setting that lets traffic pass through)"* && "$1" == *"the app does not change it"* ]]' _ "$a"
assert_success "HOST_STATE_FAILED action says restart Home Assistant Green from the System page" \
    bash -c '[[ "$1" == *"restart Home Assistant Green from the System page"* ]]' _ "$a"
a="$(halow_error_action BACKEND_FAILED)"
assert_success "BACKEND_FAILED action mentions a port only conditionally" \
    bash -c '[[ "$1" == *"If the details name a port"* && "$1" != *"the port named in the details"* ]]' _ "$a"
assert_success "BACKEND_FAILED summary covers the protective network rules" \
    bash -c '[[ "$1" == *"network"* && "$1" == *"set up or kept running"* ]]' _ "$(halow_error_summary BACKEND_FAILED)"
assert_success "NM_CHECK_FAILED summary says Home Assistant is kept from managing the adapter and the network" \
    bash -c '[[ "$1" == *"Home Assistant"* && "$1" == *"managing the adapter"* ]]' _ "$(halow_error_summary NM_CHECK_FAILED)"

echo "-- the approved customer copy (product name, no menu sequences, no internal phrasing) --"
assert_success "NO_ADAPTER uses the full product name" \
    bash -c '[[ "$1" == *"Morse Micro Wi-Fi HaLow USB Network Adapter"* ]]' _ "$(halow_error_summary NO_ADAPTER)"
assert_success "MULTIPLE_ADAPTERS uses the full product name" \
    bash -c '[[ "$1" == *"Morse Micro Wi-Fi HaLow USB Network Adapter"* ]]' _ "$(halow_error_summary MULTIPLE_ADAPTERS)"
assert_success "UNSUPPORTED_KERNEL action says the access point stays off and no new changes are applied" \
    bash -c '[[ "$1" == *"Until then the Wi-Fi HaLow access point stays off, and the app does not apply new radio or network changes."* ]]' _ "$(halow_error_action UNSUPPORTED_KERNEL)"
for code in $EXPECTED_CODES; do
    both="$(halow_error_summary "$code") $(halow_error_action "$code")"
    assert_success "$code wording does not say 'makes no changes to your system'" \
        bash -c '[[ "$1" != *"makes no changes to your system"* ]]' _ "$both"
    assert_success "$code wording has no 'Reboot system' menu label" \
        bash -c '[[ "$1" != *"Reboot system"* ]]' _ "$both"
    assert_success "$code wording never says 'the Green'" \
        bash -c '! sed "s/Home Assistant Green//g" <<< "$1" | grep -qiE "the Green"' _ "$both"
    assert_success "$code wording has no em dash" \
        bash -c '[[ "$1" != *—* ]]' _ "$both"
done

echo "-- ROLLBACK_INCOMPLETE and STATUS_STALE --"
s="$(halow_error_summary ROLLBACK_INCOMPLETE)"; a="$(halow_error_action ROLLBACK_INCOMPLETE)"
assert_success "ROLLBACK_INCOMPLETE says it could not confirm the undo and does not apply new changes" bash -c '[[ "$1" == *"could not confirm"* && "$1" == *"does not apply new radio or network changes"* ]]' _ "$s"
assert_success "ROLLBACK_INCOMPLETE recommends restarting Home Assistant Green from the System page" bash -c '[[ "$1" == "Restart Home Assistant Green from the System page"* ]]' _ "$a"
assert_success "ROLLBACK_INCOMPLETE says this restarts the whole Home Assistant system" \
    bash -c '[[ "$1" == *"restarts your whole Home Assistant system"* ]]' _ "$a"
assert_eq "Restart the app. If the message stays, check the app's Log tab." "$(halow_error_action STATUS_STALE)" "STATUS_STALE says restart the app, then check the Log tab"

echo "-- the advisory --"
assert_success "RADIO_AUTO_FALLBACK is an advisory" halow_error_is_advisory RADIO_AUTO_FALLBACK
assert_failure "RADIO_AUTO_FALLBACK is not recoverable-retry class" halow_error_retryable RADIO_AUTO_FALLBACK
for code in NO_ADAPTER STATUS_STALE INTERNAL_ERROR; do
    assert_failure "$code is not an advisory" halow_error_is_advisory "$code"
done
s="$(halow_error_summary RADIO_AUTO_FALLBACK)"; a="$(halow_error_action RADIO_AUTO_FALLBACK)"
assert_success "advisory says selection did not complete and a backup channel is used" \
    bash -c '[[ "$1" == *"did not complete"* && "$1" == *"backup channel"* ]]' _ "$s"
assert_success "advisory says selection can be retried by restarting the app" bash -c '[[ "$1" == *"Restart the app to try automatic selection again"* ]]' _ "$a"
assert_success "advisory is never worded as a success" \
    bash -c 'l="${1,,}"; [[ "$l" != *success* && "$l" != *"selected the"* ]]' _ "$s $a"

echo "-- unknown and malformed codes --"
for bad in "" "BOGUS" "no_adapter" "NO_ADAPTER " "NO_ADAPTER STATUS_STALE" "NO-ADAPTER" '$(id)'; do
    assert_failure "unknown code '$bad' is not known" halow_error_known "$bad"
    assert_failure "unknown code '$bad' has no summary" halow_error_summary "$bad"
    assert_failure "unknown code '$bad' has no action" halow_error_action "$bad"
    assert_failure "unknown code '$bad' is not recoverable" halow_error_retryable "$bad"
done
assert_eq "" "$(halow_error_summary BOGUS)" "nothing printed for an unknown code"

echo "-- re-sourceable, and safe under strict mode --"
. "$HALOW_STATUS_LIB_DIR/errors.sh"
. "$HALOW_STATUS_LIB_DIR/errors.sh"
assert_eq "18" "$(halow_error_list | wc -l | tr -d ' ')" "re-sourcing keeps the catalogue intact"
assert_success "sourcing inside a function then using it in strict mode" \
    bash -c 'set -o errexit -o errtrace -o nounset -o pipefail; shopt -s inherit_errexit
             f() { . "$1/errors.sh"; }; f "$1"
             halow_error_summary NO_ADAPTER >/dev/null
             if halow_error_known BOGUS; then exit 1; fi
             halow_error_retryable UPLINK_UNAVAILABLE' _ "$HALOW_STATUS_LIB_DIR"

echo "test_errors: $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed"
exit $([ "$HALOW_TEST_FAILURES" -eq 0 ] && echo 0 || echo 1)
