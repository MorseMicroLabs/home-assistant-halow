#!/usr/bin/env bash
# Tests firmware.sh: success placement, checksum mismatch, pre-existing foreign host
# artifact, pre-existing byte-identical-but-unowned artifact (must never be reclaimed),
# idempotent restart, directory ownership, and ownership-gated cleanup.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh

echo "== test_firmware =="
halow_test_setup

src="$HALOW_ARTIFACTS_DIR/mm8108b2-rl.bin"
printf 'fake firmware content' > "$src"
sha="$(sha256sum "$src" | awk '{print $1}')"
dest="$HALOW_FW_DIR/mm8108b2-rl.bin"

# --- Scenario: success, including directory creation/ownership ---
assert_file_absent "$HALOW_FW_DIR" "the destination directory does not exist before placement (not pre-created by the test)"
assert_exit 0 "fresh firmware placement succeeds and is owned" \
    halow_place_firmware "$src" "$dest" "$sha" "firmware_main" "firmware_dir"
assert_file_exists "$dest" "firmware file exists after placement"
assert_success "ownership recorded after successful placement" \
    halow_own_check "firmware_main"
assert_success "the destination directory's own creation is tracked" \
    halow_own_check "firmware_dir"

# --- Scenario: idempotent restart ---
assert_exit 0 "re-placing already-correct, already-owned firmware is idempotent" \
    halow_place_firmware "$src" "$dest" "$sha" "firmware_main" "firmware_dir"

# --- Scenario: cleanup ownership (files and the directory they were in) ---
assert_success "removal succeeds for an owned, unmodified file" \
    halow_remove_firmware "$dest" "$sha" "firmware_main" "firmware_dir"
assert_file_absent "$dest" "firmware file removed after cleanup"
assert_failure "ownership cleared after removal" \
    halow_own_check "firmware_main"
assert_file_absent "$HALOW_FW_DIR" "the package-created, now-empty directory is removed too"
assert_failure "directory ownership cleared after its removal" \
    halow_own_check "firmware_dir"

# --- Scenario: pre-existing foreign host artifact — must fail closed, never overwrite ---
mkdir -p "$HALOW_FW_DIR"
printf 'completely unrelated pre-existing content' > "$dest"
assert_exit 1 "placement refuses to overwrite a pre-existing, non-matching file" \
    halow_place_firmware "$src" "$dest" "$sha" "firmware_main" "firmware_dir"
assert_eq "completely unrelated pre-existing content" "$(cat "$dest")" \
    "the foreign file's content is untouched after the refused placement"
assert_failure "no ownership is claimed over a foreign file" \
    halow_own_check "firmware_main"
assert_failure "no ownership is claimed over the pre-existing directory either" \
    halow_own_check "firmware_dir"
rm -rf "$HALOW_FW_DIR"

# --- Scenario: pre-existing, byte-identical, but NOT package-owned — must be usable,
# but never later claimed or deleted (this was a real defect: an earlier version of
# this code auto-reclaimed ownership of any byte-identical file, which would have let
# this package later delete a foreign file that merely happened to match). ---
mkdir -p "$HALOW_FW_DIR"
cp "$src" "$dest"
assert_exit 2 "placement reports 'usable but unowned' for byte-identical pre-existing content" \
    halow_place_firmware "$src" "$dest" "$sha" "firmware_main" "firmware_dir"
assert_failure "ownership is NOT claimed over the byte-identical foreign file" \
    halow_own_check "firmware_main"
halow_remove_firmware "$dest" "$sha" "firmware_main" "firmware_dir" >/dev/null 2>&1
assert_file_exists "$dest" "the foreign, byte-identical file is NEVER removed, since it was never owned"
rm -rf "$HALOW_FW_DIR"

# --- Scenario: checksum mismatch on the source itself — refuse before touching dest ---
assert_exit 1 "placement refuses a source that fails its own checksum" \
    halow_place_firmware "$src" "$dest" "0000000000000000000000000000000000000000000000000000000000000" "firmware_main" "firmware_dir"
assert_file_absent "$dest" "nothing is written when the source checksum is wrong"

# --- Scenario: removal refuses when content changed since placement (fail closed) ---
halow_place_firmware "$src" "$dest" "$sha" "firmware_main" "firmware_dir" >/dev/null
printf 'tampered after placement' > "$dest"
assert_failure "removal refuses to delete content that changed since placement" \
    halow_remove_firmware "$dest" "$sha" "firmware_main" "firmware_dir"
assert_file_exists "$dest" "the changed file is left in place, not deleted"
assert_success "ownership is NOT cleared on a refused removal (keeps surfacing the problem)" \
    halow_own_check "firmware_main"

# --- Scenario: directory ownership is never claimed when the directory already existed ---
rm -rf "$HALOW_FW_DIR" "${HALOW_STATE_DIR:?}/owns"
mkdir -p "$HALOW_FW_DIR"
halow_place_firmware "$src" "$dest" "$sha" "firmware_main" "firmware_dir" >/dev/null
assert_failure "directory ownership is not claimed when the directory pre-existed" \
    halow_own_check "firmware_dir"
halow_remove_firmware "$dest" "$sha" "firmware_main" "firmware_dir" >/dev/null
assert_file_exists "$HALOW_FW_DIR" "a pre-existing directory is never removed, even after the file inside it is cleaned up"

halow_test_teardown
echo "test_firmware: $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed"
exit $([ "$HALOW_TEST_FAILURES" -eq 0 ] && echo 0 || echo 1)
