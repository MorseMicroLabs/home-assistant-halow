#!/usr/bin/env bash
# lifecycle.sh: backoff, the retry policy and the manager restart counter.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh

echo "== test_lifecycle =="
halow_test_setup >/dev/null 2>&1
. "$HALOW_LIB_DIR/lifecycle.sh"

echo "-- backoff: 5, 10, 20, 40, 80, then capped at 120 --"
for pair in 1:5 2:10 3:20 4:40 5:80 6:120 7:120 50:120; do
    assert_eq "${pair#*:}" "$(halow_backoff_next "${pair%%:*}")" "attempt ${pair%%:*} waits ${pair#*:} s"
done
assert_eq "5" "$(halow_backoff_next 0)" "attempt 0 is treated as the first"
assert_eq "5" "$(halow_backoff_next "")" "a missing attempt is treated as the first"
assert_eq "5" "$(halow_backoff_next abc)" "an invalid attempt is treated as the first"

echo "-- retry classes --"
for c in NO_ADAPTER MULTIPLE_ADAPTERS UPLINK_UNAVAILABLE; do
    assert_eq "recoverable" "$(halow_lifecycle_retry_class "$c")" "$c is recoverable"
done
for c in AP_START_FAILED AP_DIED; do
    assert_eq "bounded" "$(halow_lifecycle_retry_class "$c")" "$c is bounded"
done
assert_eq "rollback" "$(halow_lifecycle_retry_class ROLLBACK_INCOMPLETE)" "ROLLBACK_INCOMPLETE retries rollback only"
for c in CONFIG_INVALID REGION_UNVALIDATED UNSUPPORTED_KERNEL FIRMWARE_INVALID MODULE_LOAD_FAILED HOST_STATE_FAILED BACKEND_FAILED NM_CHECK_FAILED RADIO_MISMATCH INTERNAL_ERROR SOMETHING_ELSE ""; do
    assert_eq "never" "$(halow_lifecycle_retry_class "$c")" "'$c' is never retried"
done

echo "-- should_retry --"
assert_success "NO_ADAPTER after 1000 failures is still retried (no count limit)" halow_lifecycle_should_retry NO_ADAPTER 1000
assert_success "AP_START_FAILED after 1 failure is retried" halow_lifecycle_should_retry AP_START_FAILED 1
assert_success "AP_DIED after 2 failures is retried" halow_lifecycle_should_retry AP_DIED 2
assert_failure "AP_DIED after 3 consecutive failures is not retried" halow_lifecycle_should_retry AP_DIED 3
assert_failure "AP_START_FAILED after 4 is not retried" halow_lifecycle_should_retry AP_START_FAILED 4
assert_failure "CONFIG_INVALID is never retried" halow_lifecycle_should_retry CONFIG_INVALID 1
assert_failure "UNSUPPORTED_KERNEL is never retried" halow_lifecycle_should_retry UNSUPPORTED_KERNEL 1
assert_success "ROLLBACK_INCOMPLETE (rollback only) is retried" halow_lifecycle_should_retry ROLLBACK_INCOMPLETE 9

echo "-- restart counter: in the volatile run directory, windowed, resettable --"
assert_eq "0" "$(halow_restart_count_get)" "starts at 0"
halow_restart_count_incr 1000
halow_restart_count_incr 1100
halow_restart_count_incr 1200
assert_eq "3" "$(halow_restart_count_get)" "three exits recorded"
assert_file_exists "$HALOW_RUN_DIR/manager_exits" "the counter lives in HALOW_RUN_DIR"
assert_failure "nothing in the persistent state directory" test -e "$HALOW_STATE_DIR/manager_exits"
HALOW_MANAGER_EXIT_WINDOW_S=150
assert_eq "2" "$(halow_restart_count_get 1250)" "only exits within the window count (1100 and 1200 at 1250 with 150 s)"
assert_eq "0" "$(halow_restart_count_get 99999)" "old exits fall out of the window"
HALOW_MANAGER_EXIT_WINDOW_S=600
printf 'garbage\n\n' >> "$HALOW_RUN_DIR/manager_exits"
assert_eq "3" "$(halow_restart_count_get 1300)" "malformed lines are ignored"
halow_restart_count_reset
assert_eq "0" "$(halow_restart_count_get)" "reset forgets every exit"
assert_file_absent "$HALOW_RUN_DIR/manager_exits" "reset removes the file"
rm -rf "$HALOW_RUN_DIR"
assert_eq "0" "$(halow_restart_count_get)" "a recreated container (empty run directory) counts 0"
assert_success "incr recreates the run directory" halow_restart_count_incr 5
assert_eq "1" "$(halow_restart_count_get)" "one exit after recreation"

halow_test_teardown
echo "test_lifecycle: $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed"
exit $([ "$HALOW_TEST_FAILURES" -eq 0 ] && echo 0 || echo 1)
