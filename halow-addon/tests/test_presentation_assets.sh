#!/usr/bin/env bash
# Tests the Home Assistant app presentation images (icon.png and logo.png in the app folder).
# Home Assistant recommends a square 128 x 128 pixel icon and a logo of around 250 x 100 pixels
# (https://contributors.home-assistant.io/apps/guides/presentation/). The images are the official
# Morse Micro artwork, resampled only. This test reads the PNG header with plain Python (no
# image library) and checks: PNG signature, icon exactly 128 x 128, logo not larger than 250 x 100
# with a plausible aspect ratio, an alpha channel (RGBA, color type 6), valid chunk CRCs ending in IEND, no text, EXIF or profile chunks, non-empty files under
# 200 KB, and that the images are not copied into the image build context.
# Needs bash, python3 and grep.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
. tests/test_helpers.sh

echo "== test_presentation_assets =="

cat > "${TMPDIR:-/tmp}/png_info.$$.py" <<'PYEOF'
import struct, sys, zlib, zlib
p = sys.argv[1]
d = open(p, "rb").read()
assert d[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG (bad signature)"
assert d[12:16] == b"IHDR", "first chunk is not IHDR"
w, h, depth, ctype = struct.unpack(">IIBB", d[16:26])
chunks, i = [], 8
while i < len(d):
    n = struct.unpack(">I", d[i:i + 4])[0]
    assert i + 12 + n <= len(d), "truncated chunk"
    assert zlib.crc32(d[i + 4:i + 8 + n]) == struct.unpack(">I", d[i + 8 + n:i + 12 + n])[0], "bad chunk CRC"
    chunks.append(d[i + 4:i + 8].decode("latin-1"))
    i += 12 + n
assert chunks[-1] == "IEND" and "IDAT" in chunks, "missing IDAT or IEND"
bad = [c for c in chunks if c in ("tEXt", "zTXt", "iTXt", "eXIf", "iCCP")]
assert not bad, "metadata chunks present: %s" % bad
print(w, h, depth, ctype, len(d))
PYEOF
info() { python3 -I "${TMPDIR:-/tmp}/png_info.$$.py" "$1" 2>/dev/null; }

for f in icon.png logo.png; do
    assert_file_exists "$f" "$f exists in the app folder"
    assert_success "$f has the PNG signature, valid chunk CRCs, an IHDR chunk, IEND and no metadata chunks" info "$f"
    read -r W H DEPTH CTYPE BYTES <<< "$(info "$f")"
    assert_eq "2" "${CTYPE:-}" "$f is opaque RGB (PNG color type 2, no alpha channel, so every pixel is opaque)"
    assert_eq "8" "${DEPTH:-}" "$f is 8 bits per channel"
    assert_success "$f is not empty and is below 200 KB" bash -c '[ "$1" -gt 0 ] && [ "$1" -lt 204800 ]' _ "${BYTES:-0}"
    eval "${f%.png}_W=${W:-0} ${f%.png}_H=${H:-0}"
done

echo "-- sizes --"
assert_eq "128x128" "${icon_W}x${icon_H}" "icon.png is exactly 128 x 128 pixels (square, as Home Assistant recommends)"
assert_eq "250x100" "${logo_W}x${logo_H}" "logo.png is exactly 250 x 100 pixels (the size Home Assistant recommends)"

echo "-- build context --"
assert_failure "the .dockerignore does not admit the images into the image build context" grep -qE '^![[:space:]]*(icon|logo)\.png' .dockerignore
assert_failure "the Dockerfile does not copy the images into the image" grep -qE '(icon|logo)\.png' Dockerfile
assert_success ".gitattributes treats PNG files as binary" grep -qE '^\*\.png[[:space:]]+binary' "../.gitattributes"

rm -f "${TMPDIR:-/tmp}/png_info.$$.py"
exit $([ "$HALOW_TEST_FAILURES" -eq 0 ] && echo 0 || echo 1)
