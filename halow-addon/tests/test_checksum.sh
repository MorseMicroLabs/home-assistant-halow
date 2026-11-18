#!/usr/bin/env bash
# Tests checksum.sh: verify_file_checksum, verify_manifest, checksum_for.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh

echo "== test_checksum =="
halow_test_setup

f="$HALOW_TEST_TMP/sample.bin"
printf 'hello world' > "$f"
sha="$(sha256sum "$f" | awk '{print $1}')"

assert_success "verify_file_checksum succeeds on a correct hash" \
    halow_verify_file_checksum "$f" "$sha"

assert_failure "verify_file_checksum fails on a wrong hash" \
    halow_verify_file_checksum "$f" "0000000000000000000000000000000000000000000000000000000000000"

assert_failure "verify_file_checksum fails on a missing file" \
    halow_verify_file_checksum "$HALOW_TEST_TMP/does-not-exist" "$sha"

# Manifest: one correct entry, one deliberately wrong entry — must fail closed overall.
manifest="$HALOW_TEST_TMP/MANIFEST.sha256"
{
    echo "$sha  ./sample.bin"
    echo "0000000000000000000000000000000000000000000000000000000000000  ./sample.bin"
} > "$manifest"
assert_failure "verify_manifest fails closed when any entry mismatches" \
    halow_verify_manifest "$manifest" "$HALOW_TEST_TMP"

manifest_ok="$HALOW_TEST_TMP/MANIFEST.ok.sha256"
echo "$sha  ./sample.bin" > "$manifest_ok"
assert_success "verify_manifest succeeds when every entry matches" \
    halow_verify_manifest "$manifest_ok" "$HALOW_TEST_TMP"

# checksum_for: lookup from the artifacts manifest.
cp "$f" "$HALOW_ARTIFACTS_DIR/sample.bin"
echo "$sha  ./sample.bin" > "$HALOW_ARTIFACTS_DIR/MANIFEST.sha256"
looked_up="$(halow_checksum_for "sample.bin")"
assert_eq "$sha" "$looked_up" "checksum_for finds the right entry by filename"

assert_failure "checksum_for fails closed for an unknown filename" \
    halow_checksum_for "does-not-exist.bin"

# Regression test: a real build.sh run under Windows Git Bash produced the "*"-prefixed
# binary-mode sha256sum format, while WSL2 produced the plain two-space text-mode
# format, for byte-identical input — both must parse identically.
manifest_binary_mode="$HALOW_TEST_TMP/MANIFEST.binarymode.sha256"
printf '%s *./sample.bin\n' "$sha" > "$manifest_binary_mode"
looked_up_binary="$(halow_checksum_for "sample.bin" "$manifest_binary_mode")"
assert_eq "$sha" "$looked_up_binary" "checksum_for parses the '*'-prefixed binary-mode sha256sum format too"
assert_success "verify_manifest also accepts the '*'-prefixed binary-mode format" \
    halow_verify_manifest "$manifest_binary_mode" "$HALOW_TEST_TMP"

# Regression test for a real, live defect (found during a real Green
# execution attempt, 2026-10-20, immediately after the separate MANIFEST.sha256
# packaging defect above was fixed): MANIFEST.sha256's own real BCF entry is nested
# (`./bcf/bcf_boardtype_0807.bin`), but run/rollback.sh both looked it up by the bare
# filename alone, which halow_checksum_for's own exact relative-path matching (by
# design, never basename-only or suffix matching -- that could wrongly match a
# same-named file in an unrelated directory) could never find. Fixed in both files
# (pass the subdirectory-prefixed name); this proves the matching primitive itself
# behaves correctly both ways, independent of which caller does or doesn't include the
# prefix.
manifest_nested="$HALOW_TEST_TMP/MANIFEST.nested.sha256"
echo "$sha  ./bcf/sample.bin" > "$manifest_nested"
nested_looked_up="$(halow_checksum_for "bcf/sample.bin" "$manifest_nested")"
assert_eq "$sha" "$nested_looked_up" \
    "a nested manifest entry (./bcf/sample.bin) is found when looked up with its own subdirectory-prefixed name"
assert_failure "a bare filename does NOT match a nested manifest entry -- no basename-only or suffix fallback, never a silent or ambiguous match" \
    halow_checksum_for "sample.bin" "$manifest_nested"

halow_test_teardown

echo "== test_checksum: Dockerfile packaging — MANIFEST.sha256 is staged into the exact runtime path halow_checksum_for's own default reads =="
# Regression test for a real, live defect (found during a real Green
# execution attempt, 2026-10-20): the Dockerfile copied artifacts/ into the image but
# had no instruction copying MANIFEST.sha256 alongside it, so halow_checksum_for's own
# default manifest path (above) was empty in every built image -- never caught by any
# of this file's own test fixtures, which always create that file themselves in a temp
# directory, never checking whether the REAL Dockerfile actually ships it. This is a
# static, Docker-free check (grepping the real Dockerfile's own text), so it runs on
# every off-device test pass, not only when a real image is built and
# tests/verify_image.sh (which also checks this, live, inside a real built image) is
# separately run. **A text-level check only** — it cannot detect a future
# `.dockerignore` exclusion or other build-context trick that would still leave the
# file absent from a real build despite this exact line being present; that is exactly
# what tests/verify_image.sh's own live, in-image check (above) is for, and remains
# necessary even with this check passing.
assert_success "Dockerfile has a COPY instruction staging MANIFEST.sha256 to /opt/halow/artifacts/ (either the exact-destination or directory-destination form)" \
    grep -qE '^COPY[[:space:]]+(artifacts/[[:space:]]+)?MANIFEST\.sha256[[:space:]]+/opt/halow/artifacts/(MANIFEST\.sha256)?[[:space:]]*$' ../Dockerfile

echo "== test_checksum: run/rollback.sh's own real BCF checksum-lookup call sites still use the nested lookup key =="
# A direct, Docker-free, Dockerfile-grep-style regression test for the exact production
# call sites, not only for the underlying library function (already covered above) or
# for test fixtures that independently re-derive a matching value without ever running
# this exact line (found by a code review of this change's own first pass: a
# fixture correctly calling halow_checksum_for with the right key does NOT, by itself,
# prove run.sh's/rollback.sh's own real lookup key is still correct, since neither file
# is ever sourced or executed by the off-device test suite -- only this kind of direct
# text check can catch a regression in the real production line itself without a real
# container boot). If either file's own lookup key ever regresses back to the bare
# filename (the exact originally-reported bug), this fails immediately.
assert_success "the manager's own BCF checksum lookup uses the nested key (bcf/\$HALOW_FW_BCF_NAME), not the bare filename" \
    grep -qF 'halow_checksum_for "bcf/$HALOW_FW_BCF_NAME"' ../rootfs/usr/lib/halow/manager.sh
assert_success "rollback.sh's own BCF checksum lookup uses the nested key (bcf/\$HALOW_FW_BCF_NAME), not the bare filename" \
    grep -qF 'halow_checksum_for "bcf/$HALOW_FW_BCF_NAME"' ../rootfs/usr/lib/halow/rollback.sh

echo "test_checksum: $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed"
exit $([ "$HALOW_TEST_FAILURES" -eq 0 ] && echo 0 || echo 1)
