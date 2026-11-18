#!/usr/bin/env bash
# Tests the provenance and licence record (../provenance.psv) against the artifact
# manifest (../MANIFEST.sha256) and, when the staged artifacts are present, against the
# actual files:
#   - every bundled artifact has a row, with the same checksum, and every file row names
#     an artifact that is really in the manifest (no orphan, no missing entry);
#   - no field of any row is empty (source, pinned ref, licence, licence text, check status);
#   - the licence-check and redistribution fields use only the documented values;
#   - the narrative (PROVENANCE.md) names every artifact.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh

PSV="../provenance.psv"
MAN="../MANIFEST.sha256"
NARR="../PROVENANCE.md"

echo "== test_provenance_manifest =="
assert_file_exists "$PSV" "the machine-checked provenance record exists"
assert_file_exists "$MAN" "the artifact manifest exists"
assert_file_exists "$NARR" "the provenance narrative exists"

rows="$(grep -v -E '^[[:space:]]*(#|$)' "$PSV")"
nrows="$(printf '%s\n' "$rows" | grep -c .)"
assert_eq "110" "$nrows" "the record has one row per bundled artifact (7), per embedded third-party component (OpenSSL, glibc, libnl, libgcc, the rate-control code), per Alpine package in the image (80), and per other image component (14 base-image programs including jemalloc, the base image itself, its pip.conf, the CA bundle file, the add-on's own files)"
assert_eq "80" "$(grep -c '^image-package:' "$PSV")" "every Alpine package of the built image has a row"
assert_eq "18" "$(grep -c '^image-component:' "$PSV")" "the non-apk image components (including jemalloc), the base image, its configuration file and the add-on's own files have rows"

echo "-- every row is complete --"
bad_fields=0; bad_status=0
while IFS= read -r row; do
    n="$(awk -F'|' '{print NF}' <<< "$row")"
    [ "$n" -eq 10 ] || { bad_fields=1; echo "    row with $n fields: ${row%%|*}"; continue; }
    for i in 1 2 3 4 5 6 7 8 9 10; do
        v="$(awk -F'|' -v i="$i" '{gsub(/^[ \t]+|[ \t]+$/, "", $i); print $i}' <<< "$row")"
        [ -n "$v" ] || { bad_fields=1; echo "    empty field $i in row: ${row%%|*}"; }
    done
    chk="$(awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $8); print $8}' <<< "$row")"
    red="$(awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $9); print $9}' <<< "$row")"
    case "$chk" in confirmed|apkbuild-confirmed|from-bundle-record|unverified) ;; *) bad_status=1; echo "    bad licence_check '$chk' in ${row%%|*}" ;; esac
    case "$red" in approved) ;; *) bad_status=1; echo "    redistribution is not approved (the owner approved redistribution; a row may not stay not-assessed) '$red' in ${row%%|*}" ;; esac
done <<< "$rows"
assert_eq "0" "$bad_fields" "every row has exactly ten non-empty fields"
assert_eq "0" "$bad_status" "licence_check uses only the documented values and EVERY redistribution field is approved"

echo "-- the record and the manifest agree --"
missing=0; mismatch=0
while read -r sha path; do
    [ -n "$sha" ] || continue
    row="$(printf '%s\n' "$rows" | awk -F'|' -v p="$path" '{k = $1; gsub(/^[ \t]+|[ \t]+$/, "", k); if (k == p) print $0}')"
    if [ -z "$row" ]; then missing=1; echo "    no provenance row for $path"; continue; fi
    rsha="$(awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' <<< "$row")"
    [ "$rsha" = "$sha" ] || { mismatch=1; echo "    checksum differs for $path"; }
done < <(grep -v -E '^[[:space:]]*(#|$)' "$MAN")
assert_eq "0" "$missing" "every artifact in the manifest has a provenance row"
assert_eq "0" "$mismatch" "every provenance row carries the manifest's own checksum"
orphans=0
while IFS= read -r p; do
    case "$p" in
        ./*) grep -q -F "  $p" "$MAN" || { orphans=1; echo "    row for $p has no manifest entry"; } ;;
        embedded:*|image-package:*|image-component:*) ;;
        *) orphans=1; echo "    unrecognised path form: $p" ;;
    esac
done < <(awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $1); print $1}' <<< "$rows")
assert_eq "0" "$orphans" "every file row names an artifact that is in the manifest"
assert_success "the third-party library statically linked into hostapd has its own row" grep -q '^embedded:openssl |' "$PSV"

echo "-- the staged artifacts, when present, are exactly the recorded ones --"
if [ -d ../artifacts ]; then
    actual="$(cd ../artifacts && find . -type f ! -name MANIFEST.sha256 | sort)"
    recorded="$(awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $1); print $1}' <<< "$rows" | grep '^\./' | sort)"
    assert_eq "$recorded" "$actual" "the files in artifacts/ are exactly the files with a provenance row"
    sumbad=0
    while read -r sha path; do
        [ -n "$sha" ] || continue
        [ "$(cd ../artifacts && sha256sum "$path" | cut -d' ' -f1)" = "$sha" ] || { sumbad=1; echo "    checksum of staged $path differs"; }
    done < <(grep -v -E '^[[:space:]]*(#|$)' "$MAN")
    assert_eq "0" "$sumbad" "every staged artifact matches its recorded checksum"
else
    echo "  SKIP: ../artifacts is not staged here; the staged-file checks (2 assertions) were not run (run build.sh first)"; HALOW_SKIPPED=2
fi

echo "-- the artifact count in the prose is the manifest's --"
nart="$(grep -v -E '^[[:space:]]*(#|$)' "$MAN" | grep -c .)"
declare -A NUMWORD=( [5]=five [6]=six [7]=seven [8]=eight [9]=nine )
assert_eq "7" "$nart" "the manifest lists seven artifacts"
word="${NUMWORD[$nart]:-}"
assert_success "PROVENANCE.md states that count in words ($word staged artifact files, $word bundled artifacts)" bash -c 'grep -q "the $1 staged artifact files" "$3" && grep -q "the $1 bundled artifacts" "$3"' _ "$word" "$nart" "$NARR"
for w in five six eight nine ten; do
    [ "$w" = "$word" ] && continue
    assert_failure "PROVENANCE.md has no stale count word '$w' before 'staged artifact files' or 'bundled artifacts'" grep -qE "the $w (staged artifact files|bundled artifacts)" "$NARR"
done
assert_success "the hostapd rows record BSD-3-Clause AND ISC and name the dual-licensed radiotap file used under ISC" bash -c '[ "$(grep -c "^./hostapd_s1g \|^./hostapd_cli_s1g " "$1")" -ge 2 ] && [ "$(grep -c "BSD-3-Clause AND ISC" "$1")" -ge 2 ] && grep -q "radiotap.c" "$1" && grep -q "Confirmed for .hostapd_s1g. and .hostapd_cli_s1g." "$2"' _ "$PSV" "$NARR"

echo "-- the narrative names every artifact --"
while read -r sha path; do
    [ -n "$sha" ] || continue
    base="$(basename "$path")"
    assert_success "PROVENANCE.md names $base" grep -q -F "$base" "$NARR"
done < <(grep -v -E '^[[:space:]]*(#|$)' "$MAN")
assert_success "PROVENANCE.md records the redistribution approval" grep -q -i "redistribution is approved" "$NARR"
assert_success "PROVENANCE.md separates the staged artifacts from image dependencies" grep -q -i "Not covered — dependencies of the container image" "$NARR"
assert_success "PROVENANCE.md states the depth of verification and does not claim the image is reproducible bit for bit" bash -c 'grep -q "Depth of verification" "$1" && grep -q -i "bit for bit" "$1"' _ "$NARR"
assert_failure "PROVENANCE.md no longer says that full-image provenance has not been completed (the inventory covers every component)" grep -q -i "full-image provenance has not been completed" "$NARR"
assert_success "PROVENANCE.md says the 110 rows cover every component found in the image" grep -q "cover every component found in the image" "$NARR"

echo "test_provenance_manifest: $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed, ${HALOW_SKIPPED:-0} assertions skipped (artifacts not staged)"
exit $([ "$HALOW_TEST_FAILURES" -eq 0 ] && echo 0 || echo 1)
