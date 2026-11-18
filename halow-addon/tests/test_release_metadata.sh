#!/usr/bin/env bash
# Tests the release metadata invariants (version 1.0.0, stage stable): boot auto, the version
# and its consistency with the Dockerfile labels, build.sh and the changelog, the `image` key
# (present, never a tag, exactly the approved registry path), the license files (LICENSE and
# NOTICE present and correct, no repository file yet), and the release checklist script itself. Needs only bash, awk, grep and sha256sum.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh

echo "== test_release_metadata =="

ADDON=".."
CONFIG="$ADDON/config.yaml"
DOCKERFILE="$ADDON/Dockerfile"
CHANGELOG="$ADDON/CHANGELOG.md"
SCRIPT="$ADDON/tools/release_candidate_checklist.sh"
_top() { awk -v k="$1" -F': *' '$1 == k { v = $2; sub(/[[:space:]]+#.*$/, "", v); gsub(/^"|"$/, "", v); print v; exit }' "$CONFIG"; }
EMDASH="$(printf '\xe2\x80\x94')"

echo "-- start on boot --"
assert_eq "auto" "$(_top boot)" "boot: auto"
assert_eq "1" "$(grep -c '^boot:' "$CONFIG")" "boot is set exactly once"

echo "-- version scheme --"
version="$(_top version)"
assert_success "the manifest version is quoted in config.yaml" grep -qE '^version: "[^"]+"' "$CONFIG"
assert_eq "1.0.0" "$version" "the manifest version is the first release, 1.0.0"
assert_eq "stable" "$(_top stage)" "the Home Assistant stage is stable (it travels with version 1.0.0)"
assert_eq "1" "$(grep -c '^stage:' "$CONFIG")" "stage is set exactly once"
rel="$(awk -F'"' '/^RELEASE_VERSION=/ { print $2 }' "$SCRIPT")"
assert_eq "$version" "$rel" "the checklist script names the same release version as the manifest"
assert_failure "breaking_versions does not list the release version" grep -qx "  - \"$version\"" "$CONFIG"

echo "-- no migration or earlier-version text in the first release --"
assert_failure "the operations guide carries no instruction about an earlier slug or an unpublished test installation" bash -c 'tr "
" " " < "$1" | tr -s " " | grep -qiE "earlier slug|halow_ap_dev|unpublished test installation"' _ "$ADDON/docs/OPERATIONS.md"
assert_failure "the customer changelog carries no migration, uninstall or earlier-version instructions" bash -c 'tr "
" " " < "$1" | tr -s " " | grep -qiE "uninstall|old slug|slug|earlier development|0\.4\.0|release candidate"' _ "$CHANGELOG"
assert_failure "the customer changelog does not mention rebooting or a firmware path" bash -c 'tr "
" " " < "$1" | tr -s " " | grep -qiE "reboot|firmware"' _ "$CHANGELOG"

echo "-- version consistency --"
assert_success "io.hass.version label equals the manifest version" grep -qF "io.hass.version=\"$version\"" "$DOCKERFILE"
assert_success "the OCI image version label equals the manifest version" grep -qF "org.opencontainers.image.version=\"$version\"" "$DOCKERFILE"
assert_eq "2" "$(grep -cE '^[[:space:]]*(io\.hass\.version|org\.opencontainers\.image\.version)=' "$DOCKERFILE")" "the Dockerfile carries exactly two version labels"
assert_eq "0" "$(grep -c '0\.3\.2-dev' "$DOCKERFILE")" "no stale development version in the Dockerfile"
assert_success "build.sh reads the version from config.yaml" grep -qF "config.yaml" "$ADDON/build.sh"
assert_success "build.sh refuses a Dockerfile label that differs from the manifest version" \
    grep -qF 'does not equal the config.yaml version' "$ADDON/build.sh"
assert_success "build.sh records the version as an image label" grep -qF 'io.halow.build.version=${VERSION}' "$ADDON/build.sh"
assert_success "build.sh tags the image with the version" grep -qF 'morse-micro-halow-ap:${VERSION}' "$ADDON/build.sh"
assert_success "the changelog has an entry for the manifest version" grep -qE "^## \[?${version//./\\.}\]?( |\$)" "$CHANGELOG"

echo "-- image key, name and registry --"
image="$(_top image)"
assert_eq "ghcr.io/morsemicrolabs/home-assistant-halow" "$image" "the image key is the approved registry path, with no tag and no {arch} placeholder"
assert_failure "the image value carries no tag (the tag is always the version)" bash -c '[[ "${0##*/}" == *:* ]]' "$image"
assert_eq "1" "$(grep -c "^image:" "$CONFIG")" "image is set exactly once"
assert_success "the slug uses only letters, digits, hyphen, underscore and dot" grep -qE '^slug: [A-Za-z0-9_.-]+$' "$CONFIG"
assert_eq "Morse Micro Wi-Fi HaLow Access Point for Home Assistant" "$(awk '/^name:/ { sub(/^name:[[:space:]]*/, ""); print; exit }' "$CONFIG")" "the name is the settled customer-visible name"
# Registry hosts, assembled from fragments so that this file does not hold them itself.
REG_RX="gh""cr\\.io|docker""\\.io|qua""y\\.io|registry-1|\\.pkg\\.dev|amazonaws\\.com"
assert_eq "1" "$(grep -vE '^[[:space:]]*#' "$CONFIG" | grep -cE "$REG_RX")" "config.yaml (outside comments) names the registry host only in the image key"
assert_eq "0" "$(grep -cE "$REG_RX" "$CHANGELOG")" "the changelog names no registry host"
assert_eq "0" "$(grep -cE "$REG_RX" "$SCRIPT")" "the checklist script names no registry host"
assert_eq "0" "$(grep -vE '^FROM ' "$DOCKERFILE" | grep -cE "$REG_RX")" "the Dockerfile names no registry host outside its base-image line"
assert_eq "0" "$(grep -cE "$REG_RX" "$ADDON/build.sh")" "build.sh names no registry host (it never pushes)"
assert_eq "0" "$(cat "$ADDON/build.sh" "$SCRIPT" | grep -cE 'docker (push|login)')" "no script pushes or logs in to a registry"

echo "-- license files present and correct; the repository file not yet present --"
APACHE_SHA="cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30"
for d in "$ADDON" "$ADDON/.."; do
    assert_eq "$APACHE_SHA" "$(sha256sum "$d/LICENSE" 2>/dev/null | cut -d' ' -f1)" "$d/LICENSE is the verbatim Apache License 2.0 text"
    assert_success "$d/NOTICE exists and names the product and the license boundary" bash -c 'grep -q "^Morse Micro Wi-Fi HaLow Access Point for Home Assistant$" "$0" && grep -q "GPL-2.0-only" "$0" && grep -q "Apache License, Version 2.0" "$0"' "$d/NOTICE"
done
for f in LICENSE.md LICENSE.txt NOTICE.md NOTICE.txt repository.yaml repository.yml repository.json; do
    assert_failure "$f is not in the add-on directory" test -e "$ADDON/$f"
done
for f in LICENSE.md LICENSE.txt NOTICE.md NOTICE.txt repository.yml repository.json; do
    assert_failure "$f is not at the repository root" test -e "$ADDON/../$f"
done
assert_success "repository.yaml is at the repository root" test -s "$ADDON/../repository.yaml"
assert_success "repository.yaml names the Morse Micro Labs repository" bash -c 'grep -q "^name: \"Morse Micro Labs\"$" "$0" && grep -q "^url: \"https://github.com/MorseMicroLabs/home-assistant-halow\"$" "$0" && grep -q "^maintainer: \"Morse Micro Labs\"$" "$0"' "$ADDON/../repository.yaml"
assert_failure "repository.yaml has no image field" grep -qE "^image:" "$ADDON/../repository.yaml"

echo "-- changelog style --"
assert_success "CHANGELOG.md exists" test -s "$CHANGELOG"
assert_failure "the changelog carries no draft marker" grep -qiE "draft|pending approval" "$CHANGELOG"
assert_success "the changelog states the license treatment (Apache License 2.0 for the application code, GPL-2.0-only driver modules)" bash -c 'tr "
" " " < "$1" | tr -s " " | grep -qF "the application code is licensed under the Apache License 2.0. The Morse Micro driver modules the app loads remain under GPL-2.0-only"' _ "$CHANGELOG"
assert_success "the changelog has a Known Issues section (Title Case heading)" grep -qE "^### Known Issues$" "$CHANGELOG"
assert_success "the changelog has a What This Version Includes section" grep -qE "^### What This Version Includes$" "$CHANGELOG"
assert_failure "the changelog carries no numbered group tag like [1 " grep -qE '\[[0-9] ' "$CHANGELOG"
assert_failure "the changelog says 'the Green' only as part of Home Assistant Green" bash -c 'tr "\n" " " < "$1" | tr -s " " | sed "s/Home Assistant Green//g" | grep -qE "[Tt]he Green"' _ "$CHANGELOG"
assert_failure "the changelog has no raw URL and no placeholder text" grep -qiE 'https?://|PLACEHOLDER' "$CHANGELOG"
assert_eq "0" "$(grep -ciE "add-on" "$CHANGELOG")" "the changelog says app, not add-on"
assert_eq "0" "$(grep -c "$EMDASH" "$CHANGELOG")" "the changelog has no em dash"
assert_eq "0" "$(grep -c "$EMDASH" "$SCRIPT")" "the checklist script has no em dash"
assert_eq "0" "$(grep -E 'HaLow' "$CHANGELOG" | sed -E 's/Wi-Fi HaLow//g; s/Wi-Fi-HaLow//g; s/HaLowLink//g' | grep -c 'HaLow')" "'HaLow' never stands alone in the changelog (only Wi-Fi HaLow and the default network name Wi-Fi-HaLow)"
assert_success "the changelog states the default network name Wi-Fi-HaLow" grep -qF "network name of Wi-Fi-HaLow" "$CHANGELOG"
assert_eq "Wi-Fi-HaLow" "$(awk -F'"' '/^  wifi_ssid:/ { print $2; exit }' "$CONFIG")" "the default wifi_ssid in config.yaml is exactly Wi-Fi-HaLow"
assert_eq "0" "$(grep -ciE 'seamless|revolutionary|cutting-edge|game-changing|unleash|best-in-class' "$CHANGELOG")" "the changelog uses no banned marketing words"
# 8 MHz channel 43: stated as history and as an unvalidated change, never as an accepted
# limitation or an interim workaround (the access point program is now the release that
# matches the driver).
for doc in "$ADDON/README.md" "$CHANGELOG" "$ADDON/translations/en.yaml" "$ADDON/docs/ARCHITECTURE.md"; do
    assert_eq "0" "$(tr '
' ' ' < "$doc" | tr -s ' ' | grep -ciE 'interim measure|as an interim|under investigation|select manual channel selection and channel 35|reported not to associate')" "$(basename "$doc") has no interim-workaround or accepted-limitation wording about channel 43"
done
# One flat copy of each document (newlines folded) for phrase checks.
flat() { tr '
' ' ' < "$1" | tr -s ' '; }
# Customer text carries no test or validation history (that belongs in internal records).
for doc in "$ADDON/README.md" "$CHANGELOG" "$ADDON/translations/en.yaml"; do
    assert_eq "0" "$(flat "$doc" | grep -c -i -E 'limited evidence|source analysis|live-validated|not yet been validated|channel 43')" "$(basename "$doc") carries no test-history wording"
done
for doc in "$ADDON/README.md" "$CHANGELOG" "$ADDON/translations/en.yaml" "$ADDON/docs/ARCHITECTURE.md"; do
    assert_eq "0" "$(flat "$doc" | grep -o -i -E '(has|was|were|have) (now |been )?validated' | wc -l | tr -d ' ')" "$(basename "$doc") never says the change or anything else 'has/was/were validated' (only 'not yet been validated')"
    assert_eq "0" "$(flat "$doc" | grep -c -i -E 'found to drop|supervised|(this|that|the) correction')" "$(basename "$doc") has no 'found to drop', no 'supervised', and does not call the change a correction"
done
assert_failure "the customer changelog names no driver release, bundled helper program or morse_cli" bash -c 'tr "\n" " " < "$1" | tr -s " " | grep -qiE "mm8108|morse_cli|helper program|no longer bundled|access point program"' _ "$CHANGELOG"
assert_eq "0" "$(grep -ci 'morse_cli' "$ADDON/README.md" "$ADDON/translations/en.yaml" "$ADDON/docs/ARCHITECTURE.md" | awk -F: '{s += $2} END {print s}')" "the README, the translations and the architecture notes name no helper program that is not shipped"

echo "-- the release checklist script --"
assert_success "the script passes bash -n" bash -n "$SCRIPT"
assert_failure "the device-session checklist mode is gone (an internal test procedure does not ship)" bash "$SCRIPT" live
assert_failure "an unknown mode is refused" bash "$SCRIPT" bogus

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/halow-addon/tools" "$tmp/halow-addon/rootfs/usr/share/halow"
cp "$SCRIPT" "$tmp/halow-addon/tools/"
cp "$CONFIG" "$DOCKERFILE" "$CHANGELOG" "$ADDON/README.md" "$ADDON/MANIFEST.sha256" "$tmp/halow-addon/"
cp "$ADDON/LICENSE" "$ADDON/NOTICE" "$tmp/halow-addon/"
cp "$ADDON/rootfs/usr/share/halow/guard_manifest.psv" "$tmp/halow-addon/rootfs/usr/share/halow/"
S="$tmp/halow-addon/tools/release_candidate_checklist.sh"
# The README names the manifest version (a separate suite checks that too); give the copy a
# line that does, so that this test isolates the metadata checks.
printf '\n`%s`\n' "$version" >> "$tmp/halow-addon/README.md"
assert_success "preflight passes on a consistent tree (no suite run and no image: those are NOT CHECKED)" bash "$S" preflight
assert_success "preflight reports unchecked items rather than passing them" bash -c '"$0" preflight | grep -q "NOT CHECKED"' "$S"
assert_failure "preflight fails for a target release the guard manifest lacks" env HALOW_RC_TARGET_RELEASE="0.0.0-none" bash "$S" preflight
known="$(awk -F'|' '$1 == "release" { print $2; exit }' "$tmp/halow-addon/rootfs/usr/share/halow/guard_manifest.psv")"
if [ -n "$known" ]; then
    assert_success "preflight accepts a target release the guard manifest carries" env HALOW_RC_TARGET_RELEASE="$known" bash "$S" preflight
fi
sed -i 's/^\(    io.hass.version=\)"[^"]*"/\1"9.9.9-rc.9"/' "$tmp/halow-addon/Dockerfile"
assert_failure "preflight fails when a Dockerfile label differs from the manifest" bash "$S" preflight
cp "$DOCKERFILE" "$tmp/halow-addon/Dockerfile"
sed -i 's/^boot: auto/boot: manual/' "$tmp/halow-addon/config.yaml"
assert_failure "preflight fails when boot is not auto" bash "$S" preflight
cp "$CONFIG" "$tmp/halow-addon/config.yaml"
rm -f "$tmp/halow-addon/LICENSE"
assert_failure "preflight fails when the LICENSE file is missing" bash "$S" preflight
cp "$ADDON/LICENSE" "$tmp/halow-addon/LICENSE"
rm -f "$tmp/halow-addon/NOTICE"
assert_failure "preflight fails when the NOTICE file is missing" bash "$S" preflight
cp "$ADDON/NOTICE" "$tmp/halow-addon/NOTICE"
touch "$tmp/halow-addon/repository.yaml"
assert_failure "preflight fails when a repository file appears (the Labs layout adds it later)" bash "$S" preflight
rm -f "$tmp/halow-addon/repository.yaml"
sed -i 's/^version: .*/version: "1.2.3"/' "$tmp/halow-addon/config.yaml"
assert_failure "preflight fails when the version is not the release version" bash "$S" preflight
cp "$CONFIG" "$tmp/halow-addon/config.yaml"
sed -i 's/^stage: .*/stage: experimental/' "$tmp/halow-addon/config.yaml"
assert_failure "preflight fails when the stage is not stable" bash "$S" preflight
cp "$CONFIG" "$tmp/halow-addon/config.yaml"
sed -i '/^image:/d' "$tmp/halow-addon/config.yaml"
assert_failure "preflight fails when the image key is missing" bash "$S" preflight

echo "test_release_metadata: $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed"
[ "$HALOW_TEST_FAILURES" -eq 0 ]
