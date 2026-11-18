#!/usr/bin/env bash
# Tests tools/final_release_gate.sh against synthetic fixture trees (an all-green tree passes;
# each gate blocks when its own condition is violated), and asserts that the real current tree
# is BLOCKED, so the gate cannot be passed by accident while the release decisions are open.
# The gate is not a development pass requirement: only this test of the script itself is.
# Needs only bash, awk, grep, sed, od and sha256sum. Writes only to a temp directory.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh

echo "== test_final_release_gate =="

ADDON=".."
GATE="$ADDON/tools/final_release_gate.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# make_png <file> <width> <height>: PNG signature plus an IHDR chunk header with the given size
# (width and height are below 256 here, so each is one low byte after three zero bytes).
make_png() {
    { printf '\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x00'
      printf "\\x$(printf %02x "$2")"
      printf '\x00\x00\x00'
      printf "\\x$(printf %02x "$3")"
      printf 'xxxx'; } > "$1"
}

# The synthetic source assets: one small archive, the index and the preparation script, plus
# SHA256SUMS. Every fixture tree carries the same manifest, so one directory serves them all.
FIXA="$tmp/assets"; mkdir -p "$FIXA/pkg/fixture"
printf 'fixture source\n' > "$FIXA/pkg/fixture/README"
tar -C "$FIXA/pkg" -czf "$FIXA/fixture-source.tar.gz" fixture; rm -rf "$FIXA/pkg"
printf '# Source index\n' > "$FIXA/SOURCE-INDEX.md"
printf '#!/bin/sh\n' > "$FIXA/kernel-prep.sh"
URLB="https://github.com/MorseMicroLabs/home-assistant-halow/releases/download/v1.0.0/"
{ echo "# url_base: $URLB"
  for n in fixture-source.tar.gz SOURCE-INDEX.md kernel-prep.sh; do
      case "$n" in *.tar.gz) k=tar.gz; m="fixture/README" ;; *) k=text; m="-" ;; esac
      echo "$n | $(stat -c %s "$FIXA/$n") | $(sha256sum "$FIXA/$n" | awk '{print $1}') | fixture | none | $m | $k | note"
  done; } > "$tmp/ASSETS.psv.fixture"
( cd "$FIXA" && sha256sum fixture-source.tar.gz SOURCE-INDEX.md kernel-prep.sh | sed 's/ \*/  /' | sort -k2 ) > "$FIXA/SHA256SUMS"
export HALOW_SOURCE_ASSETS_DIR="$FIXA"
export HALOW_REQUIRED_SOURCE_ASSETS="fixture-source.tar.gz SOURCE-INDEX.md kernel-prep.sh"
export HALOW_PUBLICATION_CHECK_TEST=1
MSHA="$(sha256sum "$tmp/ASSETS.psv.fixture" | awk '{print $1}')"

# A minimal, all-green tree. License texts are copied from the real tree (the gate compares
# their hashes with the recorded ones).
make_tree() { # make_tree <dir>
    local d="$1" a="$1/halow-addon"
    rm -rf "$d"
    mkdir -p "$a/LICENSES" "$d/LICENSES" "$d/docs"
    cp "$ADDON/LICENSES/Apache-2.0.txt" "$ADDON/LICENSES/GPL-2.0-only.txt" "$a/LICENSES/"
    cp "$ADDON/LICENSES/Apache-2.0.txt" "$ADDON/LICENSES/GPL-2.0-only.txt" "$d/LICENSES/"
    printf 'Apache-2.0 for the application.\n' > "$d/LICENSE"; cp "$d/LICENSE" "$a/LICENSE"
    printf 'Morse Micro Wi-Fi HaLow Access Point for Home Assistant\nCopyright 2026 Morse Micro\n' > "$d/NOTICE"
    cp "$d/NOTICE" "$a/NOTICE"
    printf 'name: Fixture\nversion: "1.0.0"\nslug: fixture\nstage: stable\nimage: ghcr.io/example/fixture\n' > "$a/config.yaml"
    printf 'LABEL \\\n    io.hass.type="app" \\\n    io.hass.version="1.0.0" \\\n    org.opencontainers.image.version="1.0.0" \\\n    org.opencontainers.image.description="Wi-Fi HaLow access point."\n' > "$a/Dockerfile"
    printf '# Fixture\n\nVersion 1.0.0.\n' > "$d/README.md"; cp "$d/README.md" "$a/README.md"
    printf '# Changelog\n\n## [1.0.0]\n' > "$a/CHANGELOG.md"
    printf 'Install steps.\n' > "$d/docs/guide.md"
    printf '# header\n./a.bin | 00 | A | s | r | Apache-2.0 | t | confirmed | assessed-ok | n\n' > "$a/provenance.psv"
    printf '# Corresponding source\n\nAssets at %s: fixture-source.tar.gz, SOURCE-INDEX.md, kernel-prep.sh.\n' "$URLB" > "$a/SOURCE-OFFER.md"
    mkdir -p "$a/source-assets" "$a/source-offer"
    cp "$tmp/ASSETS.psv.fixture" "$a/source-assets/ASSETS.psv"
    cp "$FIXA/SOURCE-INDEX.md" "$a/source-assets/SOURCE-INDEX.md"
    cp "$FIXA/kernel-prep.sh" "$a/source-offer/kernel-prep.sh"
    printf '# publication status\nstatus: published\nmanifest-sha256: %s\n' "$MSHA" > "$a/source-assets/PUBLICATION-STATUS"
    make_png "$a/icon.png" 128 128; make_png "$a/logo.png" 250 100
    printf '[[annotations]]\nSPDX-FileCopyrightText = "Copyright 2026 Morse Micro"\nSPDX-License-Identifier = "LicenseRef-Fixture"\n' > "$d/REUSE.toml"
    printf 'Fixture license text.\n' > "$d/LICENSES/LicenseRef-Fixture.txt"
    printf '# Docs\n' > "$a/DOCS.md"
    printf '# Security\n\nhttps://www.morsemicro.com/policy/security-disclosure\n' > "$d/SECURITY.md"
}

# blocks <tree> <gate-number> <message>: the gate exits non-zero and that gate's line is BLOCK.
blocks() {
    local out rc
    out="$(bash "$GATE" "$1" 2>&1)"; rc=$?
    HALOW_TEST_COUNT=$((HALOW_TEST_COUNT + 1))
    if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q "^BLOCK: \[$2\] "; then
        echo "  ok: $3"
    else
        echo "  FAIL: $3 (exit $rc; output:)"; printf '%s\n' "$out" | sed 's/^/    | /'
        HALOW_TEST_FAILURES=$((HALOW_TEST_FAILURES + 1))
    fi
}
# only_blocks <tree> <gate-number> <message>: as blocks, and no other gate blocks.
only_blocks() {
    local out n
    out="$(bash "$GATE" "$1" 2>&1)"
    n="$(printf '%s\n' "$out" | grep -c '^BLOCK: ')"
    blocks "$1" "$2" "$3"
    assert_eq "1" "$n" "  (only gate $2 blocks)"
}

echo "-- modes --"
assert_eq "14" "$(bash "$GATE" --list | wc -l | tr -d ' ')" "--list prints the fourteen gate names"
assert_eq "[1] version-and-stage" "$(bash "$GATE" --list | head -1)" "--list names gate 1"
assert_eq "0" "$(bash "$GATE" --list | grep -c -E 'PASS|BLOCK')" "--list prints no gate results"
assert_exit 2 "a missing root path is a usage error" bash "$GATE" "$tmp/does-not-exist"

echo "-- all-green fixture --"
t="$tmp/green"; make_tree "$t"
assert_exit 0 "the all-green fixture passes (exit 0)" bash "$GATE" "$t"
assert_eq "14" "$(bash "$GATE" "$t" | grep -c '^PASS: ')" "all fourteen gates print PASS"
assert_eq "0" "$(bash "$GATE" "$t" | grep -c '^BLOCK: ')" "no gate prints BLOCK"
assert_exit 0 "the default root resolves from the script location in a copied tree" \
    bash -c 'mkdir -p "$1/halow-addon/tools" && cp "$2" "$3" "$1/halow-addon/tools/" && bash "$1/halow-addon/tools/final_release_gate.sh"' _ "$t" "$GATE" "$ADDON/tools/verify_source_assets.sh"
rm -f "$t/halow-addon/tools/final_release_gate.sh" "$t/halow-addon/tools/verify_source_assets.sh"; rmdir "$t/halow-addon/tools"

echo "-- gate 1: version and stage --"
t="$tmp/g1"; make_tree "$t"; sed -i 's/^version: .*/version: "0.4.0-rc.1"/; s/^stage: .*/stage: experimental/' "$t/halow-addon/config.yaml"
only_blocks "$t" 1 "version 0.4.0-rc.1 with stage experimental blocks"
make_tree "$t"; sed -i 's/^version: .*/version: "0.4.0-rc.1"/' "$t/halow-addon/config.yaml"
blocks "$t" 1 "version 0.4.0-rc.1 with stage stable blocks (mixed)"
make_tree "$t"; sed -i 's/^stage: .*/stage: experimental/' "$t/halow-addon/config.yaml"
blocks "$t" 1 "version 1.0.0 with stage experimental blocks (mixed)"
make_tree "$t"; sed -i 's/^version: .*/version: "1.0.1"/' "$t/halow-addon/config.yaml"
blocks "$t" 1 "a version other than 1.0.0 blocks"
make_tree "$t"; sed -i 's/org.opencontainers.image.version="1.0.0"/org.opencontainers.image.version="0.4.0-rc.1"/' "$t/halow-addon/Dockerfile"
blocks "$t" 1 "a Dockerfile version label that differs from 1.0.0 blocks"

echo "-- gate 2: image key --"
t="$tmp/g2"; make_tree "$t"; sed -i '/^image:/d' "$t/halow-addon/config.yaml"
only_blocks "$t" 2 "an absent image key blocks"
make_tree "$t"; sed -i 's|^image: .*|image: ghcr.io/example/fixture:1.0.0|' "$t/halow-addon/config.yaml"
blocks "$t" 2 "an image value with a tag blocks"
make_tree "$t"; sed -i 's|^image: .*|image: "[PENDING: registry]"|' "$t/halow-addon/config.yaml"
blocks "$t" 2 "an image value with an unresolved marker blocks"
make_tree "$t"; sed -i 's|^image: .*|image: |' "$t/halow-addon/config.yaml"
blocks "$t" 2 "an empty image value blocks"
make_tree "$t"; sed -i 's|^image: .*|image: localhost:5000/example/fixture|' "$t/halow-addon/config.yaml"
assert_exit 0 "an untagged image whose registry host has a port passes" bash "$GATE" "$t"

echo "-- gate 3: unresolved markers --"
for f in README.md halow-addon/README.md halow-addon/CHANGELOG.md docs/guide.md halow-addon/config.yaml; do
    t="$tmp/g3"; make_tree "$t"; printf '[PENDING: something]\n' >> "$t/$f"
    blocks "$t" 3 "a [PENDING marker in $f blocks"
done
t="$tmp/g3"; make_tree "$t"; printf '# GHCR-DEPENDENT: x\n' >> "$t/halow-addon/config.yaml"
blocks "$t" 3 "a GHCR-DEPENDENT marker in config.yaml blocks"
make_tree "$t"; printf 'name: x\n# GHCR-DEPENDENT: x\n' > "$t/repository.yaml"
blocks "$t" 3 "a GHCR-DEPENDENT marker in repository.yaml blocks"
make_tree "$t"; printf 'a\n[PENDING: y]\n' > "$t/docs/guide.md"
assert_success "the gate reports file:line for a marker" bash -c 'bash "$1" "$2" | grep -q "docs/guide.md:2"' _ "$GATE" "$t"

echo "-- gate 4: RELEASE-TODO.md --"
t="$tmp/g4"; make_tree "$t"; : > "$t/RELEASE-TODO.md"
only_blocks "$t" 4 "RELEASE-TODO.md at the root blocks"
make_tree "$t"; mkdir -p "$t/halow-addon/docs"; : > "$t/halow-addon/docs/RELEASE-TODO.md"
only_blocks "$t" 4 "RELEASE-TODO.md at any depth blocks"

echo "-- gate 5: license files --"
for f in LICENSE NOTICE LICENSES/Apache-2.0.txt LICENSES/GPL-2.0-only.txt halow-addon/LICENSE halow-addon/LICENSES/Apache-2.0.txt; do
    t="$tmp/g5"; make_tree "$t"; rm -f "$t/$f"
    blocks "$t" 5 "a missing $f blocks"
done
t="$tmp/g5"; make_tree "$t"; printf 'x\n' >> "$t/LICENSES/Apache-2.0.txt"
blocks "$t" 5 "an altered Apache-2.0 text blocks (hash differs)"
make_tree "$t"; printf 'x\n' >> "$t/halow-addon/LICENSES/GPL-2.0-only.txt"
blocks "$t" 5 "an altered GPL-2.0-only text blocks (hash differs)"

echo "-- gate 6: redistribution records --"
t="$tmp/g6"; make_tree "$t"; printf './b.bin | 00 | B | s | r | MIT | t | unverified | not-assessed | n\n' >> "$t/halow-addon/provenance.psv"
only_blocks "$t" 6 "a not-assessed provenance row blocks"
assert_success "the block reports the not-assessed count" bash -c 'bash "$1" "$2" | grep -q "1 provenance.psv rows have redistribution not-assessed"' _ "$GATE" "$t"
make_tree "$t"; rm -f "$t/halow-addon/provenance.psv"
blocks "$t" 6 "a missing provenance.psv blocks"

echo "-- gate 7: icon and logo --"
for f in icon.png logo.png; do
    t="$tmp/g7"; make_tree "$t"; rm -f "$t/halow-addon/$f"
    blocks "$t" 7 "a missing $f blocks"
    make_tree "$t"; printf 'not a png' > "$t/halow-addon/$f"
    blocks "$t" 7 "a $f without the PNG signature blocks"
done

t="$tmp/g7"; make_tree "$t"; make_png "$t/halow-addon/icon.png" 64 64
blocks "$t" 7 "an icon.png that is not 128x128 blocks"
make_tree "$t"; make_png "$t/halow-addon/logo.png" 251 100
blocks "$t" 7 "a logo.png wider than 250 blocks"
make_tree "$t"; make_png "$t/halow-addon/logo.png" 250 101
blocks "$t" 7 "a logo.png taller than 100 blocks"
make_tree "$t"; make_png "$t/halow-addon/logo.png" 100 50
assert_exit 0 "a logo.png within 250x100 passes" bash "$GATE" "$t"


echo "-- gate 6: method-neutral completed states --"
SO="halow-addon/SOURCE-OFFER.md"
make_tree "$t"; printf './b.bin | 00 | B | s | r | MIT | t | unverified | not-assessed | n\r\n' >> "$t/halow-addon/provenance.psv"
blocks "$t" 6 "a not-assessed row blocks"
make_tree "$t"; printf './b.bin | 00 | B | s | r | MIT | t | unverified | not-assessed\r\n' >> "$t/halow-addon/provenance.psv"
blocks "$t" 6 "a not-assessed last field with CRLF still blocks"

make_tree "$t"; printf './b.bin | 00 | B | s | r | MIT | t | unverified | Not Assessed | n
' >> "$t/halow-addon/provenance.psv"
blocks "$t" 6 "a differently written not assessed value still blocks"
make_tree "$t"; printf './b.bin | 00 | B | s | r | MIT | t | unverified |  | n
' >> "$t/halow-addon/provenance.psv"
blocks "$t" 6 "an empty redistribution field blocks"
for ph in "The source is not yet supplied." "Nothing is archived." "The app has not been publicly released." "The repository is private until the release."; do
    make_tree "$t"; printf 'Assets at %s: fixture-source.tar.gz, SOURCE-INDEX.md, kernel-prep.sh.

%s
' "$URLB" "$ph" > "$t/$SO"
    blocks "$t" 13 "'$ph' in SOURCE-OFFER.md blocks gate 13"
done
make_tree "$t"; : > "$t/halow-addon/DOCS.md"
blocks "$t" 10 "an empty DOCS.md blocks"

echo "-- gate 13: source assets prepared and verified (private preparation) --"
t="$tmp/g13"; make_tree "$t"; printf '# publication status\nstatus: prepared\n' > "$t/halow-addon/source-assets/PUBLICATION-STATUS"
assert_exit 0 "private-preparation mode passes with prepared assets and status prepared" bash "$GATE" --private-preparation "$t"
assert_success "...and reports the publication gate as pending, not as a pass" bash -c 'o="$(bash "$1" --private-preparation "$2")"; echo "$o" | grep -q "^PENDING: \[14\]" && ! echo "$o" | grep -q "^PASS: \[14\]"' _ "$GATE" "$t"
assert_failure "the full gate still blocks while the status is prepared" bash "$GATE" "$t"
blocks "$t" 14 "gate 14 blocks while the source assets are only prepared"
assert_success "...and its message points at the publication check tool" bash -c 'bash "$1" "$2" | grep "^BLOCK: \[14\]" | grep -q final_publication_check' _ "$GATE" "$t"
assert_exit 0 "the status published, with the manifest checksum it was checked against, passes the full gate" bash "$GATE" "$(make_tree "$tmp/g13p"; echo "$tmp/g13p")"
make_tree "$t"; printf 'status: published\n' > "$t/halow-addon/source-assets/PUBLICATION-STATUS"
blocks "$t" 14 "published without the manifest checksum line blocks gate 14"
make_tree "$t"; printf 'status: published\nmanifest-sha256: %s\n' "$(printf '0%.0s' $(seq 64))" > "$t/halow-addon/source-assets/PUBLICATION-STATUS"
blocks "$t" 14 "published with a stale manifest checksum blocks gate 14"
assert_success "...and says that the checksum is not that of the current manifest" bash -c 'bash "$1" "$2" | grep "^BLOCK: \[14\]" | grep -q "not the sha256 of the current ASSETS.psv"' _ "$GATE" "$t"
make_tree "$t"; printf '# Corresponding source\n\nAssets at %s: fixture-source.tar.gz, SOURCE-INDEX.md, kernel-prep.sh.\n\nThe source is published.\n' "$URLB" > "$t/halow-addon/SOURCE-OFFER.md"
printf '# publication status\nstatus: prepared\n' > "$t/halow-addon/source-assets/PUBLICATION-STATUS"
blocks "$t" 13 "text saying the source is published while the status is prepared blocks gate 13"
make_tree "$t"
assert_failure "a set that lacks a required asset blocks gate 13 even when the manifest and the assets agree (the real required list)" env -u HALOW_REQUIRED_SOURCE_ASSETS bash "$GATE" --private-preparation "$t"
assert_success "...and names the missing required asset" bash -c 'env -u HALOW_REQUIRED_SOURCE_ASSETS bash "$1" --private-preparation "$2" | grep "^BLOCK: \[13\]" | grep -q "does not list the required asset linux-6.18.58.tar.xz"' _ "$GATE" "$t"
make_tree "$t"; rm -f "$t/halow-addon/source-assets/PUBLICATION-STATUS"
blocks "$t" 13 "a missing PUBLICATION-STATUS blocks gate 13"
make_tree "$t"; printf 'status: maybe\n' > "$t/halow-addon/source-assets/PUBLICATION-STATUS"
blocks "$t" 13 "an unknown publication status blocks gate 13"
make_tree "$t"; rm -f "$t/halow-addon/source-assets/ASSETS.psv"
blocks "$t" 13 "a missing manifest blocks gate 13"
make_tree "$t"; sed -i 's#download/v1.0.0/#download/v9.9.9/#' "$t/halow-addon/source-assets/ASSETS.psv"
blocks "$t" 13 "an address base for another version blocks gate 13"
make_tree "$t"; printf '# Corresponding source\n\nNo assets named here.\n' > "$t/halow-addon/SOURCE-OFFER.md"
blocks "$t" 13 "a SOURCE-OFFER.md that does not name every asset blocks gate 13"
make_tree "$t"; rm -f "$t/halow-addon/source-offer/kernel-prep.sh"
blocks "$t" 13 "a missing kernel-prep.sh blocks gate 13"
make_tree "$t"; rm -f "$t/halow-addon/source-assets/SOURCE-INDEX.md"
blocks "$t" 13 "a missing SOURCE-INDEX.md blocks gate 13"
make_tree "$t"; sed -i 's/^fixture-source.tar.gz | [0-9]*/fixture-source.tar.gz | 1/' "$t/halow-addon/source-assets/ASSETS.psv"
blocks "$t" 13 "a wrong recorded size blocks gate 13 (the local asset does not match)"
make_tree "$t"; sed -i 's/^\(SOURCE-INDEX.md | [0-9]* | \)[0-9a-f]\{64\}/\1'"$(printf '0%.0s' $(seq 64))"'/' "$t/halow-addon/source-assets/ASSETS.psv"
blocks "$t" 13 "a wrong recorded sha256 blocks gate 13"
make_tree "$t"
assert_failure "without an assets directory gate 13 cannot pass" env -u HALOW_SOURCE_ASSETS_DIR bash "$GATE" --private-preparation "$t"
assert_success "...and says the assets were not verified" bash -c 'env -u HALOW_SOURCE_ASSETS_DIR bash "$1" "$2" | grep "^BLOCK: \[13\]" | grep -q "not verified"' _ "$GATE" "$t"
assert_exit 0 "--assets DIR is accepted in place of the environment variable" env -u HALOW_SOURCE_ASSETS_DIR bash "$GATE" --assets "$FIXA" "$t"
cp -r "$FIXA" "$tmp/assets-bad"; printf 'x\n' >> "$tmp/assets-bad/fixture-source.tar.gz"
assert_failure "a local asset that no longer matches the manifest blocks" bash "$GATE" --assets "$tmp/assets-bad" "$t"
rm -f "$tmp/assets-bad/SHA256SUMS"
assert_failure "an assets directory without SHA256SUMS blocks" bash "$GATE" --assets "$tmp/assets-bad" "$t"
cp -r "$FIXA" "$tmp/assets-extra"; echo stray > "$tmp/assets-extra/stray.bin"
assert_failure "an extra file among the assets blocks" bash "$GATE" --assets "$tmp/assets-extra" "$t"
rm -rf "$tmp/assets-bad" "$tmp/assets-extra"

echo "-- verify_source_assets.sh and final_publication_check.sh --"
VER="$ADDON/tools/verify_source_assets.sh"; PUB="$ADDON/tools/final_publication_check.sh"
t="$tmp/vs"; make_tree "$t"
assert_exit 0 "verify_source_assets passes on the fixture assets" bash "$VER" --addon "$t/halow-addon" "$FIXA"
assert_exit 0 "verify_source_assets gives the same result under another locale" env LC_ALL=en_US.UTF-8 bash "$VER" --addon "$t/halow-addon" "$FIXA"
assert_exit 2 "verify_source_assets without a directory is a usage error" bash "$VER" --addon "$t/halow-addon"
cp -r "$FIXA" "$tmp/va"; printf '# changed\n' > "$tmp/va/SOURCE-INDEX.md"
assert_failure "an index that differs from the repository copy fails" bash "$VER" --addon "$t/halow-addon" "$tmp/va"
rm -rf "$tmp/va"; cp -r "$FIXA" "$tmp/va"; : > "$tmp/va/kernel-prep.sh"
assert_failure "an empty or different kernel-prep.sh fails" bash "$VER" --addon "$t/halow-addon" "$tmp/va"
cp -r "$FIXA" "$tmp/va"; rm -f "$tmp/va/fixture-source.tar.gz"
assert_failure "a missing asset fails" bash "$VER" --addon "$t/halow-addon" "$tmp/va"
rm -rf "$tmp/va"
# the publication check: a file:// base stands for the published address
assert_exit 0 "the publication check passes (full mode is the default) when every address answers with the recorded content" env HALOW_SOURCE_URL_BASE="file://$FIXA/" bash "$PUB" --addon "$t/halow-addon"
assert_success "...and prints the two lines to record, with the manifest checksum" bash -c 'o="$(HALOW_SOURCE_URL_BASE="file://$1/" bash "$2" --addon "$3")"; echo "$o" | grep -qx "status: published" && echo "$o" | grep -qx "manifest-sha256: $4"' _ "$FIXA" "$PUB" "$t/halow-addon" "$MSHA"
assert_success "...and always prints the address base it used" bash -c 'HALOW_SOURCE_URL_BASE="file://$1/" bash "$2" --addon "$3" | grep -q "^address base: file://"' _ "$FIXA" "$PUB" "$t/halow-addon"
assert_exit 0 "the size-only mode passes on the same set" env HALOW_SOURCE_URL_BASE="file://$FIXA/" bash "$PUB" --size-only --addon "$t/halow-addon"
assert_success "...but says that it does not authorize recording published and prints no status line" bash -c 'o="$(HALOW_SOURCE_URL_BASE="file://$1/" bash "$2" --size-only --addon "$3")"; echo "$o" | grep -q "does NOT authorize" && ! echo "$o" | grep -q "^status: published"' _ "$FIXA" "$PUB" "$t/halow-addon"
assert_exit 2 "an address override without the explicit test switch is refused" env -u HALOW_PUBLICATION_CHECK_TEST HALOW_SOURCE_URL_BASE="file://$FIXA/" bash "$PUB" --addon "$t/halow-addon"
cp -r "$FIXA" "$tmp/pubsame"; printf '#!/bin/sX
' | dd of="$tmp/pubsame/kernel-prep.sh" bs=1 conv=notrunc 2>/dev/null
assert_exit 1 "full mode BLOCKs a same-size file with different content" env HALOW_SOURCE_URL_BASE="file://$tmp/pubsame/" bash "$PUB" --addon "$t/halow-addon"
assert_exit 0 "...which the size-only mode cannot see (that is why it never authorizes published)" env HALOW_SOURCE_URL_BASE="file://$tmp/pubsame/" bash "$PUB" --size-only --addon "$t/halow-addon"
rm -rf "$tmp/pubsame"; cp -r "$FIXA" "$tmp/pubnosum"; rm -f "$tmp/pubnosum/SHA256SUMS"
assert_exit 1 "the publication check BLOCKs when SHA256SUMS is not published" env HALOW_SOURCE_URL_BASE="file://$tmp/pubnosum/" bash "$PUB" --addon "$t/halow-addon"
rm -rf "$tmp/pubnosum"
mkdir -p "$tmp/pubpart"; cp "$FIXA/SOURCE-INDEX.md" "$tmp/pubpart/"
assert_exit 1 "the publication check BLOCKs when an asset is not reachable" env HALOW_SOURCE_URL_BASE="file://$tmp/pubpart/" bash "$PUB" --addon "$t/halow-addon"
assert_success "...and names the missing asset" bash -c 'HALOW_SOURCE_URL_BASE="file://$1/" bash "$2" --addon "$3" | grep -q "^BLOCK fixture-source.tar.gz"' _ "$tmp/pubpart" "$PUB" "$t/halow-addon"
printf 'short\n' > "$tmp/pubpart/fixture-source.tar.gz"; cp "$FIXA/kernel-prep.sh" "$tmp/pubpart/"
assert_exit 1 "the publication check BLOCKs when a size differs from the record" env HALOW_SOURCE_URL_BASE="file://$tmp/pubpart/" bash "$PUB" --addon "$t/halow-addon"
assert_exit 1 "the publication check BLOCKs when nothing answers at the address (a base that does not exist; the test does not contact the real release address)" env HALOW_SOURCE_URL_BASE="file:///nonexistent/" bash "$PUB" --addon "$ADDON"
assert_success "the publication check changes no file" bash -c 'before="$(find "$1" -type f -exec sha256sum {} + | sort | sha256sum)"; HALOW_SOURCE_URL_BASE="file://$2/" bash "$3" --addon "$1/halow-addon" >/dev/null; after="$(find "$1" -type f -exec sha256sum {} + | sort | sha256sum)"; [ "$before" = "$after" ]' _ "$t" "$FIXA" "$PUB"
rm -rf "$tmp/pubpart"

echo "-- gate 9: REUSE.toml copyright --"
make_tree "$t"
assert_exit 0 "the confirmed line in NOTICE and REUSE.toml passes" bash "$GATE" "$t"
make_tree "$t"; sed -i 's/"Copyright 2026 Morse Micro"/"Example Holder Inc."/' "$t/REUSE.toml"
only_blocks "$t" 9 "a REUSE.toml without the confirmed copyright text blocks"
make_tree "$t"; sed -i 's/^Copyright .*/Copyright 2026 Example Holder Inc./' "$t/NOTICE"; sed -i 's/"Copyright 2026 Morse Micro"/"Example Holder Inc."/' "$t/REUSE.toml"
assert_success "the block lists both NOTICE and REUSE.toml" bash -c 'o="$(bash "$1" "$2")"; echo "$o" | grep -q "NOTICE does not" && echo "$o" | grep -q "REUSE.toml does not"' _ "$GATE" "$t"

echo "-- gate 12: LicenseRef treatment (neutral) --"
make_tree "$t"
assert_exit 0 "a LicenseRef id with its approved text at LICENSES/<id>.txt passes" bash "$GATE" "$t"
make_tree "$t"; rm -f "$t/LICENSES/LicenseRef-Fixture.txt"
only_blocks "$t" 12 "a LicenseRef id in REUSE.toml with no text blocks"
assert_success "the block names the missing id" bash -c 'bash "$1" "$2" | grep -q "LicenseRef-Fixture"' _ "$GATE" "$t"
assert_success "the block message does not say the terms must be published" bash -c '! bash "$1" "$2" | grep -i "^BLOCK: \[12\]" | grep -qiE "must be published"' _ "$GATE" "$t"
make_tree "$t"; : > "$t/LICENSES/LicenseRef-Fixture.txt"
blocks "$t" 12 "an empty text file does not count"
make_tree "$t"; rm -f "$t/LICENSES/LicenseRef-Fixture.txt"; sed -i 's/LicenseRef-Fixture/Apache-2.0/' "$t/REUSE.toml"
assert_exit 0 "no LicenseRef id left in REUSE.toml passes (annotation changed)" bash "$GATE" "$t"
make_tree "$t"; rm -f "$t/LICENSES/LicenseRef-Fixture.txt" "$t/REUSE.toml"
assert_success "no REUSE.toml at all passes the LicenseRef part (gate 12; gate 9 blocks the missing file)" bash -c 'bash "$1" "$2" | grep -qF "PASS: [12]"' _ "$GATE" "$t"
make_tree "$t"; rm -f "$t/LICENSES/LicenseRef-Fixture.txt"; sed -i 's/^SPDX-License-Identifier = .*/# SPDX-License-Identifier = "LicenseRef-Fixture"/' "$t/REUSE.toml"
assert_exit 0 "a commented-out LicenseRef line is not a use" bash "$GATE" "$t"
make_tree "$t"; rm -f "$t/LICENSES/LicenseRef-Fixture.txt"; sed -i 's/"LicenseRef-Fixture"/"Apache-2.0 OR LicenseRef-Fixture"/' "$t/REUSE.toml"
blocks "$t" 12 "a LicenseRef id inside an SPDX expression is found"

echo "-- gate 8: halow-addon/docs and other shipped files --"
for ph in "development build" "DEVELOPMENT BUILD" "Development Build" "not production-ready" "Not Production-Ready" "development-build"; do
    make_tree "$t"; mkdir -p "$t/halow-addon/docs"; printf 'Clean line.\nSomething about the %s here.\n' "$ph" > "$t/halow-addon/docs/OPERATIONS.md"
    blocks "$t" 8 "'$ph' in halow-addon/docs/OPERATIONS.md blocks"
done
make_tree "$t"; mkdir -p "$t/halow-addon/docs/sub"; printf 'A development build.\n' > "$t/halow-addon/docs/sub/NOTES.md"
blocks "$t" 8 "a nested Markdown file under halow-addon/docs blocks"
make_tree "$t"; mkdir -p "$t/halow-addon/docs"; printf 'Clean docs.\n' > "$t/halow-addon/docs/OPERATIONS.md"
assert_exit 0 "clean halow-addon/docs passes" bash "$GATE" "$t"
make_tree "$t"; mkdir -p "$t/halow-addon/translations"; printf 'name: development build\n' > "$t/halow-addon/translations/en.yaml"
blocks "$t" 8 "development wording in translations/en.yaml blocks"
make_tree "$t"; printf 'A development build.\r\n' >> "$t/README.md"
blocks "$t" 8 "development wording with CRLF line endings blocks"
make_tree "$t"; mkdir -p "$t/halow-addon/docs"; printf 'The earlier development build.\n' > "$t/halow-addon/PROVENANCE.md"
assert_exit 0 "PROVENANCE.md (history) is not scanned" bash "$GATE" "$t"
make_tree "$t"; mkdir -p "$t/halow-addon/docs"; printf '[PENDING: x]\n' > "$t/halow-addon/docs/OPERATIONS.md"
blocks "$t" 3 "a [PENDING marker under halow-addon/docs blocks (gate 3)"
make_tree "$t"; printf 'a [pending: x] marker\n' >> "$t/README.md"
blocks "$t" 3 "a lower-case [pending marker blocks (gate 3)"

echo "-- gate 8: development wording --"
t="$tmp/g8"; make_tree "$t"; printf 'This is a development build.\n' >> "$t/README.md"
only_blocks "$t" 8 "development build in README.md blocks"
make_tree "$t"; printf 'Not production-ready.\n' >> "$t/docs/guide.md"
blocks "$t" 8 "not production-ready in docs/guide.md blocks"
make_tree "$t"; sed -i 's/Wi-Fi HaLow access point\./DEVELOPMENT BUILD./' "$t/halow-addon/Dockerfile"
blocks "$t" 8 "DEVELOPMENT BUILD in a Dockerfile label blocks"

echo "-- gate 9: copyright holder --"
t="$tmp/g9"; make_tree "$t"; sed -i 's/^Copyright .*/Copyright 2026 Morse Micro Labs Example Inc./' "$t/NOTICE"
only_blocks "$t" 9 "a NOTICE line that only begins with the confirmed text blocks (the line must match exactly)"
make_tree "$t"; sed -i '/^Copyright /d' "$t/NOTICE"
blocks "$t" 9 "a NOTICE with no Copyright line blocks"
make_tree "$t"; sed -i 's/^Copyright .*/Copyright 2025 Morse Micro/' "$t/NOTICE"
blocks "$t" 9 "a different year or holder in NOTICE blocks"
make_tree "$t"; sed -i 's/^Copyright .*/Copyright 2026 Morse Micro/' "$t/NOTICE"
assert_exit 0 "the confirmed line with a CRLF ending passes" bash "$GATE" "$t"
make_tree "$t"; rm -f "$t/REUSE.toml"
blocks "$t" 9 "a missing REUSE.toml blocks"

echo "-- gate 10: DOCS.md --"
t="$tmp/g10"; make_tree "$t"; rm -f "$t/halow-addon/DOCS.md"
only_blocks "$t" 10 "an absent DOCS.md blocks"

echo "-- gate 11: security reporting route --"
t="$tmp/g11"; make_tree "$t"; rm -f "$t/SECURITY.md"
only_blocks "$t" 11 "an absent SECURITY.md blocks"
make_tree "$t"; printf '# Security

Open a public issue.
' > "$t/SECURITY.md"
only_blocks "$t" 11 "a SECURITY.md that does not name the disclosure form blocks"

echo "-- read-only --"
t="$tmp/ro"; make_tree "$t"
before="$(cd "$t" && find . -type f -exec sha256sum {} + | sort | sha256sum)"
bash "$GATE" "$t" >/dev/null 2>&1
after="$(cd "$t" && find . -type f -exec sha256sum {} + | sort | sha256sum)"
assert_eq "$before" "$after" "running the gate changes no file in the tree"
assert_eq "0" "$(grep -cE '(^|[[:space:]])(curl|wget|docker|git|ssh|nc)[[:space:]]' "$GATE")" "the gate script calls no network, docker or git command"

echo "-- the real tree --"
# The real tree must not pass by accident. Without the local source assets gate 13 cannot pass, whatever
# the publication status; this holds before and after publication.
assert_failure "the real tree cannot pass the private-preparation gates without verified local source assets" env -u HALOW_SOURCE_ASSETS_DIR bash "$GATE" --private-preparation

echo "test_final_release_gate: $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed"
[ "$HALOW_TEST_FAILURES" -eq 0 ]
