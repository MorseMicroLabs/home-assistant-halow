#!/usr/bin/env bash
# Tests the corresponding-source record for the kernel modules, hostapd and the release assets
# (../corresponding_source.psv, ../SOURCE-OFFER.md, ../source-offer/).
#   - every row is complete and uses only the documented status values;
#   - the module source revision here is the one the provenance record pins for the modules,
#     and the build script pins the same revisions and runs the documented make command;
#   - every file the record says is stored here exists and has the recorded checksum;
#   - the kernel patch, configuration and toolchain inputs the build needs are all listed;
#   - the gaps are stated, not hidden (described rows are named in SOURCE-OFFER.md), the file
#     says it is a record and not an offer, redistribution is not claimed to be decided, and the
#     license split and where the source is recorded are stated.
# Limits: this test checks the record's form and its internal consistency (and the stored
# files' checksums). It does NOT re-fetch the kernel, patches or repositories; the recorded
# upstream checksums and commits were compared with the build machine's copies by hand and in
# review, not by this test.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
. tests/test_helpers.sh

CSV="corresponding_source.psv"
PROV="provenance.psv"
DOC="SOURCE-OFFER.md"
SCRIPT="source-offer/build-modules.sh"

echo "== test_source_offer =="
assert_file_exists "$CSV" "the corresponding-source record exists"
assert_file_exists "$DOC" "the source-offer document exists"
assert_file_exists "$SCRIPT" "the module build script exists"

rows="$(grep -v -E '^[[:space:]]*(#|$)' "$CSV")"
field() { awk -F'|' -v i="$2" '{gsub(/^[ \t]+|[ \t]+$/, "", $i); print $i}' <<< "$1"; }
row_of() { printf '%s\n' "$rows" | awk -F'|' -v k="$1" '{x=$1; gsub(/^[ \t]+|[ \t]+$/, "", x); if (x == k) print $0}'; }

echo "-- every row is complete --"
bad=0; badstatus=0; badhash=0
while IFS= read -r r; do
    n="$(awk -F'|' '{print NF}' <<< "$r")"
    [ "$n" -eq 9 ] || { bad=1; echo "    row with $n fields: ${r%%|*}"; continue; }
    for i in 1 2 3 4 5 6 7 8 9; do
        [ -n "$(field "$r" "$i")" ] || { bad=1; echo "    empty field $i in ${r%%|*}"; }
    done
    case "$(field "$r" 8)" in recorded|stored|described) ;; *) badstatus=1; echo "    bad status in ${r%%|*}" ;; esac
    h="$(field "$r" 6)"
    case "$h" in not-applicable*) ;; *) [[ "$h" =~ ^[0-9a-f]{64}$ ]] || { badhash=1; echo "    bad checksum in ${r%%|*}"; } ;; esac
done <<< "$rows"
assert_eq "0" "$bad" "every row has nine non-empty fields"
assert_eq "0" "$badstatus" "every status is recorded, stored or described"
assert_eq "0" "$badhash" "every checksum is 64 hex digits or an explicit not-applicable"

echo "-- the module source here is the one the provenance record pins --"
drv_ref="$(field "$(row_of module-driver)" 5)"
assert_eq "4ce0a0272f8ac8e2fa58eea8ff08116e493399de" "$drv_ref" "the driver commit is the recorded one"
for mod in ./morse.ko ./dot11ah.ko; do
    prow="$(awk -F'|' -v k="$mod" '{x=$1; gsub(/^[ \t]+|[ \t]+$/, "", x); if (x == k) print $0}' "$PROV")"
    assert_eq "$drv_ref" "$(field "$prow" 5)" "provenance.psv pins $mod to the same driver commit"
done
sub_ref="$(field "$(row_of module-rate-control)" 5)"
assert_success "the build script pins the driver commit" grep -q "DRIVER_COMMIT=\"$drv_ref\"" "$SCRIPT"
assert_success "...and the submodule commit" grep -q "DRIVER_SUBMODULE_COMMIT=\"$sub_ref\"" "$SCRIPT"
for flag in CONFIG_WLAN_VENDOR_MORSE=m CONFIG_MORSE_USB=y CONFIG_MORSE_USER_ACCESS=y CONFIG_MORSE_VENDOR_COMMAND=y 'KERNEL_SRC="$KERNEL_TREE"' 'CROSS_COMPILE=aarch64-buildroot-linux-gnu-'; do
    assert_success "the build script passes $flag" grep -q -F -- "$flag" "$SCRIPT"
done
assert_success "the build script compares the result with MANIFEST.sha256" grep -q 'MANIFEST.sha256' "$SCRIPT"
assert_success "the build script is valid shell" bash -n "$SCRIPT"

echo "-- every file the record says is stored exists with the recorded checksum --"
sumbad=0; nstored=0
while IFS= read -r r; do
    [ "$(field "$r" 8)" = "stored" ] || continue
    nstored=$((nstored + 1))
    path="$(field "$r" 4)"; path="${path%% *}"
    want="$(field "$r" 6)"
    if [ ! -f "$path" ]; then sumbad=1; echo "    missing: $path"; continue; fi
    [ "$(sha256sum "$path" | cut -d' ' -f1)" = "$want" ] || { sumbad=1; echo "    checksum differs: $path"; }
done <<< "$rows"
assert_eq "0" "$sumbad" "every stored file matches its recorded checksum"
assert_eq "5" "$nstored" "exactly the final kernel configuration, the toolchain configuration, the module build script, the hostapd build script and the kernel preparation script are stored"
assert_success "the stored kernel configuration is the -haos one" grep -q '^CONFIG_LOCALVERSION="-haos"$' source-offer/kernel-6.18.58-haos.config
assert_success "...with module versioning off, as the driver was built" grep -q '^# CONFIG_MODVERSIONS is not set$' source-offer/kernel-6.18.58-haos.config

echo "-- the hostapd source and build recipe are recorded and match the provenance record --"
HSCRIPT="source-offer/build-hostapd.sh"
assert_file_exists "$HSCRIPT" "the hostapd build script exists"
assert_success "the hostapd build script is valid shell" bash -n "$HSCRIPT"
hs_ref="$(field "$(row_of hostap-source)" 5)"
assert_eq "e7309b438eaec4b82f2db29e8ef7beaca3ca52c6" "$hs_ref" "the hostap source row pins the mm8108-2.1.0 commit"
for art in ./hostapd_s1g ./hostapd_cli_s1g ./hostapd_s1g.conf; do
    prow="$(awk -F'|' -v k="$art" '{x=$1; gsub(/^[ 	]+|[ 	]+$/, "", x); if (x == k) print $0}' "$PROV")"
    assert_eq "$hs_ref" "$(field "$prow" 5)" "provenance.psv pins $art to the same hostap commit"
done
assert_success "the hostapd build script pins that commit" grep -q "HOSTAP_COMMIT=\"$hs_ref\"" "$HSCRIPT"
assert_success "the hostapd build script records the -Werror workaround" grep -q -F -- '-Wno-error=unused-variable' "$HSCRIPT"
assert_success "the hostapd build script compares both executables with MANIFEST.sha256" grep -q 'MANIFEST.sha256' "$HSCRIPT"
assert_success "the hostapd build script names the two vendor-command options the tag enables" bash -c 'grep -q CONFIG_DRIVER_NL80211_MORSE "$1" && grep -q CONFIG_MORSE_5GHZ_MAPPED "$1"' _ "$HSCRIPT"
assert_eq "0" "$(grep -c -i 'morse_cli' "$CSV" "$DOC" "$HSCRIPT" | awk -F: '{s += $2} END {print s}')" "no source record mentions the helper program that is no longer shipped"

echo "-- the build inputs are all listed --"
assert_eq "9" "$(printf '%s\n' "$rows" | grep -c '^kernel-patch-')" "all nine Operating System 18.4 kernel patches are listed"
assert_eq "5" "$(printf '%s\n' "$rows" | grep -c '^kernel-config-fragment-')" "all five configuration fragments are listed"
for id in module-driver module-rate-control kernel-source os-source kernel-config-base kernel-config-final toolchain-source toolchain-config toolchain-gcc toolchain-binutils build-script hostap-source hostap-build-script; do
    assert_success "the record has a row for $id" bash -c '[ -n "$1" ]' _ "$(row_of "$id")"
done
assert_eq "6.18.58" "$(field "$(row_of kernel-source)" 5)" "the kernel version is 6.18.58"

echo "-- the gaps are stated, not hidden --"
described=""
while IFS= read -r r; do
    [ "$(field "$r" 8)" = "described" ] && described="${described}$(field "$r" 1) "
done <<< "$rows"
assert_eq "" "$described" "no input is recorded in words only any more (the kernel preparation script is stored)"
nhash=0
while IFS= read -r r; do [ "$(field "$r" 8)" = "hash-only" ] && nhash=$((nhash + 1)); done <<< "$rows"
assert_eq "0" "$nhash" "no input is merely hash-only any more"
assert_success "SOURCE-OFFER.md names the kernel preparation script and the stored build scripts" bash -c 'grep -q "kernel-prep.sh" "$1" && grep -q "build-modules.sh" "$1" && grep -q "build-hostapd.sh" "$1"' _ "$DOC"
assert_success "SOURCE-OFFER.md states the disclaimer: not a legal conclusion" grep -q -i "not a legal conclusion" "$DOC"
assert_failure "SOURCE-OFFER.md no longer says the app is a development build or is not distributed" grep -q -i -E 'development build|is not distributed' "$DOC"
assert_failure "SOURCE-OFFER.md does not describe the repository as public" grep -q -i -E 'is public|publicly available' "$DOC"
assert_success "the kernel source URL carries the pinned version" grep -q -F "linux-$(field "$(row_of kernel-source)" 5).tar.xz" "$CSV"
echo "-- the release assets: manifest, records and documents agree --"
AS="source-assets/ASSETS.psv"
assert_file_exists "$AS" "the source-asset manifest exists"
assert_file_exists "source-assets/SOURCE-INDEX.md" "the source index exists"
assert_file_exists "source-assets/PUBLICATION-STATUS" "the publication status file exists"
assert_success "the publication status is prepared or published, never anything else" bash -c 'grep -v "^#" "$1" | grep -qxE "status: (prepared|published)"' _ source-assets/PUBLICATION-STATUS
assert_failure "the publication status file is not copied into the image (build.sh stages only the manifest and the index)" bash -c 'grep -q "cp .*PUBLICATION-STATUS" build.sh || grep -q "PUBLICATION-STATUS" Dockerfile' 
arows="$(grep -v -E '^[[:space:]]*(#|$)' "$AS")"
assert_eq "12" "$(printf '%s\n' "$arows" | wc -l | tr -d ' ')" "the manifest lists twelve assets (SHA256SUMS, generated, is the thirteenth)"
assert_eq "0" "$(printf '%s\n' "$arows" | awk -F'|' 'NF != 8' | wc -l | tr -d ' ')" "every manifest row has eight fields"
base="$(sed -n 's/^# url_base: *//p' "$AS")"
assert_eq "https://github.com/MorseMicroLabs/home-assistant-halow/releases/download/v1.0.0/" "$base" "the address base is the v1.0.0 release download path"
abad=0
while IFS= read -r r; do
    n="$(field "$r" 1)"; h="$(field "$r" 3)"
    [[ "$h" =~ ^[0-9a-f]{64}$ ]] || { abad=1; echo "    bad sha256 for $n"; }
    cr="$(row_of "asset-$n")"
    [ -n "$cr" ] || { abad=1; echo "    no corresponding_source.psv row asset-$n"; continue; }
    [ "$(field "$cr" 6)" = "$h" ] || { abad=1; echo "    checksum of asset-$n differs from the manifest"; }
    grep -qF -- "$n" "$DOC" || { abad=1; echo "    $n is not named in SOURCE-OFFER.md"; }
    grep -qF -- "$n" source-assets/SOURCE-INDEX.md || [ "$n" = "SOURCE-INDEX.md" ] || { abad=1; echo "    $n is not named in SOURCE-INDEX.md"; }
done <<< "$arows"
assert_eq "0" "$abad" "every asset has a record row with the same checksum, and is named in SOURCE-OFFER.md and the index"
assert_eq "$(sha256sum source-offer/kernel-prep.sh | cut -d' ' -f1)" "$(field "$(printf '%s\n' "$arows" | grep '^kernel-prep.sh ')" 3)" "the manifest checksum of kernel-prep.sh is that of the file in the repository"
assert_eq "$(sha256sum source-assets/SOURCE-INDEX.md | cut -d' ' -f1)" "$(field "$(printf '%s\n' "$arows" | grep '^SOURCE-INDEX.md ')" 3)" "the manifest checksum of SOURCE-INDEX.md is that of the file in the repository"
assert_eq "$(sha256sum source-offer/kernel-prep.sh | cut -d' ' -f1)" "$(field "$(row_of kernel-prep-sequence)" 6)" "the kernel-prep-sequence row records the checksum of the stored script"
assert_success "kernel-prep.sh is valid shell" bash -n source-offer/kernel-prep.sh
assert_success "build-modules.sh offers DRIVER_FROM_ARCHIVE for a driver tree extracted from the source asset" grep -q 'DRIVER_FROM_ARCHIVE' source-offer/build-modules.sh
assert_eq "$(sha256sum source-offer/build-modules.sh | cut -d' ' -f1)" "$(field "$(row_of build-script)" 6)" "the build-script row records the checksum of the current build-modules.sh"
assert_failure "no shipped record says that source is not supplied, nothing is archived, or the full-image provenance has not been completed" bash -c 'grep -q -i -E "not yet supplied|nothing is archived|full-image provenance has not been completed|no written offer of source has been published" "$@"' _ "$DOC" PROVENANCE.md source_disposition.psv corresponding_source.psv
assert_failure "no shipped record or procedure says in the present tense that the source is published (publication is a later, separate state recorded in PUBLICATION-STATUS)" bash -c 'grep -q -i -E "(is|are|has been|have been|was|were) published|already published" "$@"' _ "$DOC" source-assets/SOURCE-INDEX.md PROVENANCE.md corresponding_source.psv source_disposition.psv source-assets/ASSETS.psv docs/LOCAL-IMAGE-BUILD.md
assert_failure "no shipped record says there is no source offer yet, that coverage is limited to the kernel modules, or that something is not yet covered" bash -c 'grep -q -i -E "no source offer yet|covers only the two GPL|not yet covered|no source-offer mechanism|not a published offer" "$@"' _ "$DOC" PROVENANCE.md corresponding_source.psv source_disposition.psv
assert_success "PROVENANCE.md points to the source record" grep -q 'SOURCE-OFFER.md' PROVENANCE.md
for f in SOURCE-OFFER.md PROVENANCE.md corresponding_source.psv provenance.psv source_disposition.psv; do
    assert_success "the source record file $f exists in the app folder" test -s "$f"
done
assert_failure "the customer README does not mention SOURCE-OFFER.md (the record is not customer copy)" grep -q 'SOURCE-OFFER' README.md
assert_failure "the customer README does not mention PROVENANCE.md" grep -q 'PROVENANCE' README.md
assert_failure "the customer README has no 'Source code and licenses' section until the release team approves its copy" grep -qi 'source code and licen' README.md
assert_failure "the customer README carries no placeholder link or filename" grep -qiE 'PLACEHOLDER|TODO|TBD|\]\(\)' README.md
assert_eq "0" "$(grep -v "^#" "$PROV" | grep -c -E "[|] (permitted|prohibited) [|]")" "no provenance row claims a redistribution decision"

echo "test_source_offer: $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed"
exit $([ "$HALOW_TEST_FAILURES" -eq 0 ] && echo 0 || echo 1)
