#!/usr/bin/env bash
# in-image regression test for halow_place_firmware /
# halow_remove_firmware, run with THIS image's own real bash and BusyBox utilities (cp,
# ln, stat, awk, sha256sum, mkdir, rmdir) -- never the Ubuntu/WSL host's own GNU coreutils,
# and never a static source-text check.
#
# Regression test for the 2026-10-20 live defect: halow_place_firmware's
# own `cp --preserve=mode` (a GNU coreutils long option) is not supported by this image's
# own BusyBox `cp`, so every real firmware-placement attempt failed before any file was
# ever written — never caught by the off-device (Ubuntu/WSL, real GNU cp) test suite, nor
# by tests/verify_image.sh's own prior checks, none of which exercised this function
# inside a real container. Fixed to `cp -p`. See tests/verify_image.sh for how this
# script is invoked (once against the real, fixed image; once, as a disposable negative
# control, against the original broken firmware.sh bind-mounted over the real one).
#
# Beyond the cp/BusyBox regression itself, this also exercises halow_remove_firmware's
# own two fail-closed guarantees (a code review of this file's first version
# found neither was covered by the simple place-then-remove-the-same-file happy path
# below): an unowned file is never deleted, and an owned file whose content no longer
# matches its recorded checksum is refused, not deleted, with ownership kept.
#
# This script is meant to be run as the entrypoint/argument of
# `docker run --platform linux/arm64 --entrypoint /bin/bash <image> <this file>`.
set -eu
set -o pipefail

export HALOW_STATE_DIR=/tmp/_halow_fw_check_state
export HALOW_ARTIFACTS_DIR=/opt/halow/artifacts
rm -rf "$HALOW_STATE_DIR"

# shellcheck source=/dev/null
. /usr/lib/halow/common.sh
# shellcheck source=/dev/null
. /usr/lib/halow/checksum.sh
# shellcheck source=/dev/null
. /usr/lib/halow/ownership.sh
# shellcheck source=/dev/null
. /usr/lib/halow/firmware.sh

WORK=/tmp/_halow_fw_check_work
rm -rf "$WORK"
mkdir -p "$WORK"
SRC="$WORK/src.bin"
# A distinctive, non-default mode so mode preservation is actually proven, not merely
# coincidentally correct -- this is exactly what `cp -p` exists to preserve.
printf 'halow firmware placement regression test payload\n' > "$SRC"
chmod 741 "$SRC"
SHA="$(sha256sum -- "$SRC" | awk '{print $1}')"

DEST_DIR="$WORK/placed/nested/morse"
DEST="$DEST_DIR/fw.bin"

echo "=== staging succeeds (halow_place_firmware) ==="
if ! halow_place_firmware "$SRC" "$DEST" "$SHA" "test_fw" "test_fw_dir"; then
    echo "FAIL: halow_place_firmware returned non-zero on a clean placement" >&2
    exit 1
fi

echo "=== published file content is correct ==="
dest_sha="$(sha256sum -- "$DEST" | awk '{print $1}')"
if [ "$dest_sha" != "$SHA" ]; then
    echo "FAIL: placed file content does not match the source (src=$SHA dest=$dest_sha)" >&2
    exit 1
fi

echo "=== published file mode is correct (proves cp -p actually preserved it) ==="
src_mode="$(stat -c '%a' "$SRC")"
dest_mode="$(stat -c '%a' "$DEST")"
if [ "$src_mode" != "$dest_mode" ]; then
    echo "FAIL: mode not preserved (src=$src_mode dest=$dest_mode)" >&2
    exit 1
fi
echo "mode preserved: $dest_mode"

echo "=== ownership is recorded ==="
if ! halow_own_check "test_fw"; then
    echo "FAIL: halow_own_check does not report test_fw as owned after placement" >&2
    exit 1
fi

echo "=== no temporary file remains ==="
_left="$(ls "$DEST_DIR" 2>/dev/null || true)"
# here-string, not `ls | grep -q`: under this script's `set -o pipefail` an early-exiting grep
# can make the pipeline report a false "no match" and hide a real leftover (SIGPIPE).
if grep -q '\.halow-tmp\.' <<< "$_left"; then
    echo "FAIL: a temporary staging file was left behind in $DEST_DIR" >&2
    ls -la "$DEST_DIR" >&2
    exit 1
fi

echo "=== halow_remove_firmware fail-closed: an UNOWNED file (even if its content matches) is left in place, never deleted ==="
# Placed directly, bypassing halow_place_firmware entirely, so no ownership marker is
# ever created for it -- the exact "foreign file that happens to match" case
# halow_place_firmware's own return-2 path separately documents. This is not the happy
# path: it is the first of halow_remove_firmware's own two fail-closed guarantees, and
# the simple place-then-immediately-remove-the-same-file flow above never exercises it.
UNOWNED_DEST="$WORK/unowned/fw.bin"
mkdir -p "$(dirname -- "$UNOWNED_DEST")"
printf 'halow unowned fixture content\n' > "$UNOWNED_DEST"
UNOWNED_SHA="$(sha256sum -- "$UNOWNED_DEST" | awk '{print $1}')"
if halow_own_check "unowned_fw"; then
    echo "FAIL: test setup error -- unowned_fw should not be owned before this case even runs" >&2
    exit 1
fi
if ! halow_remove_firmware "$UNOWNED_DEST" "$UNOWNED_SHA" "unowned_fw" "unowned_fw_dir"; then
    echo "FAIL: halow_remove_firmware returned non-zero for an unowned file -- it should report success (nothing to do) without touching it" >&2
    exit 1
fi
if [ ! -e "$UNOWNED_DEST" ]; then
    echo "FAIL: an UNOWNED file was deleted by halow_remove_firmware -- this is exactly the deletion this function must never perform" >&2
    exit 1
fi

echo "=== halow_remove_firmware fail-closed: an OWNED file whose content no longer matches is refused, not deleted, and ownership is kept ==="
# Placed via the real halow_place_firmware (so it IS owned), then corrupted on disk
# afterward -- simulating content that changed since placement. The happy-path
# place-then-remove flow above only ever asks halow_remove_firmware to delete content
# it just itself verified is still correct; this exercises the OTHER branch, where the
# checksum re-check inside halow_remove_firmware itself must refuse to delete.
MISMATCH_DEST="$WORK/mismatch/fw.bin"
MISMATCH_SRC="$WORK/mismatch_src.bin"
printf 'halow mismatch fixture original content\n' > "$MISMATCH_SRC"
MISMATCH_SHA="$(sha256sum -- "$MISMATCH_SRC" | awk '{print $1}')"
if ! halow_place_firmware "$MISMATCH_SRC" "$MISMATCH_DEST" "$MISMATCH_SHA" "mismatch_fw" "mismatch_fw_dir"; then
    echo "FAIL: test setup error -- could not place the mismatch-case fixture" >&2
    exit 1
fi
printf 'this content was changed after placement, so it no longer matches the recorded checksum\n' > "$MISMATCH_DEST"
if halow_remove_firmware "$MISMATCH_DEST" "$MISMATCH_SHA" "mismatch_fw" "mismatch_fw_dir"; then
    echo "FAIL: halow_remove_firmware returned success (0) removing a file whose content no longer matches its recorded checksum -- it must refuse (fail closed)" >&2
    exit 1
fi
if [ ! -e "$MISMATCH_DEST" ]; then
    echo "FAIL: a checksum-mismatched OWNED file was deleted by halow_remove_firmware -- this is exactly the deletion this function must refuse" >&2
    exit 1
fi
if ! halow_own_check "mismatch_fw"; then
    echo "FAIL: ownership for mismatch_fw was cleared despite halow_remove_firmware refusing to delete the file -- a repeated cleanup attempt would then silently skip this file forever instead of continuing to surface the problem" >&2
    exit 1
fi

echo "=== rollback/removal succeeds (halow_remove_firmware) ==="
if ! halow_remove_firmware "$DEST" "$SHA" "test_fw" "test_fw_dir"; then
    echo "FAIL: halow_remove_firmware returned non-zero removing a correctly-placed file" >&2
    exit 1
fi
if [ -e "$DEST" ]; then
    echo "FAIL: $DEST still exists after halow_remove_firmware" >&2
    exit 1
fi
if halow_own_check "test_fw"; then
    echo "FAIL: test_fw ownership marker still present after removal" >&2
    exit 1
fi
if [ -d "$DEST_DIR" ]; then
    echo "FAIL: package-created directory $DEST_DIR was not cleaned up by rollback" >&2
    exit 1
fi

rm -rf "$HALOW_STATE_DIR" "$WORK"
echo "image_firmware_placement_check.sh: all checks passed."
