#!/usr/bin/env bash
# Tests ownership.sh's halow_mkdir_tracked/halow_rmdir_tracked: tracking EACH
# individual path component actually created (not just the requested leaf, which an
# earlier version of this code tracked alone even though `mkdir -p` could have silently
# created several untracked parent levels), removal in reverse (deepest-first) order,
# stopping at a non-empty intermediate directory, and never touching a pre-existing
# ancestor.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh

echo "== test_ownership_dirs =="
halow_test_setup

# --- Scenario: two missing levels must both be created and both tracked ---
root="$HALOW_TEST_TMP/existing-root"
mkdir -p "$root"
target="$root/level1/level2"
assert_file_absent "$root/level1" "level1 does not exist before the call"
assert_success "mkdir_tracked creates two missing levels in one call" \
    halow_mkdir_tracked "$target" "test_dirs"
assert_file_exists "$target" "the full target path now exists"
assert_success "ownership is recorded for the two-level creation" \
    halow_own_check "test_dirs"

content="$(halow_own_get "test_dirs")"
count="$(printf '%s\n' "$content" | awk 'NF' | wc -l | tr -d ' ')"
assert_eq "2" "$count" "exactly the two created directories are recorded, not more, not fewer"
case "$content" in
    *"$root/level1"*"$root/level1/level2"*) echo "  ok: recorded in creation order (shallowest first)" ;;
    *) echo "  FAIL: recorded list is not in the expected shallowest-first order: $content"; HALOW_TEST_FAILURES=$((HALOW_TEST_FAILURES + 1)) ;;
esac
HALOW_TEST_COUNT=$((HALOW_TEST_COUNT + 1))

# --- Removal: both levels removed, in reverse (deepest-first) order, root untouched ---
assert_success "rmdir_tracked removes both created levels" \
    halow_rmdir_tracked "$target" "test_dirs"
assert_file_absent "$root/level1" "the shallower created directory is gone too"
assert_file_exists "$root" "the pre-existing root directory itself is never touched"
assert_failure "ownership cleared after full removal" \
    halow_own_check "test_dirs"

# --- Scenario: a directory that already exists is never claimed or later removed ---
already="$root/already-here"
mkdir -p "$already"
assert_success "mkdir_tracked on an already-existing directory is a safe no-op" \
    halow_mkdir_tracked "$already" "test_existing"
assert_failure "no ownership is claimed for a pre-existing directory" \
    halow_own_check "test_existing"
halow_rmdir_tracked "$already" "test_existing" >/dev/null
assert_file_exists "$already" "a pre-existing directory is never removed (nothing was ever owned)"

# --- Scenario: removal stops at a non-empty intermediate directory, correctly leaving
# ownership in place for the levels that could not be removed, while still removing
# whatever WAS empty. ---
target2="$root/a/b/c"
halow_mkdir_tracked "$target2" "test_partial" >/dev/null
: > "$root/a/b/leftover-file"
assert_failure "rmdir_tracked reports incomplete when an intermediate level is not empty" \
    halow_rmdir_tracked "$target2" "test_partial"
assert_file_absent "$root/a/b/c" "the deepest, empty directory is still removed"
assert_file_exists "$root/a/b" "the non-empty intermediate directory is left in place"
assert_success "ownership is kept for the remaining, unremoved directory" \
    halow_own_check "test_partial"
remaining="$(halow_own_get "test_partial")"
assert_eq "$root/a
$root/a/b" "$remaining" "only the still-present directories remain recorded, deepest-removed entry dropped"

# Clean up the leftover file and finish the removal, confirming ownership then clears.
rm -f "$root/a/b/leftover-file"
assert_success "a second rmdir_tracked call completes the removal once the obstruction is gone" \
    halow_rmdir_tracked "$target2" "test_partial"
assert_file_absent "$root/a" "every package-created level is now gone"
assert_failure "ownership fully cleared once every level is removed" \
    halow_own_check "test_partial"

# --- Scenario: mkdir failure partway through rolls back whatever was created in THIS call ---
target3="$root/x/y/z"
mkdir -p "$root/x"
chmod 555 "$root/x" 2>/dev/null || true   # make $root/x non-writable so creating "y" fails
if [ ! -w "$root/x" ]; then
    assert_failure "mkdir_tracked fails closed when an intermediate mkdir fails" \
        halow_mkdir_tracked "$target3" "test_fail"
    assert_failure "no ownership is left behind after a failed, rolled-back creation" \
        halow_own_check "test_fail"
    chmod 755 "$root/x"
else
    echo "  (skipped: this environment does not enforce directory write permissions as expected for this test)"
fi

halow_test_teardown
echo "test_ownership_dirs: $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed"
exit $([ "$HALOW_TEST_FAILURES" -eq 0 ] && echo 0 || echo 1)
