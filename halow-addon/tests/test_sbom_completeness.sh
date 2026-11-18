#!/usr/bin/env bash
# Tests that the provenance and software-bill-of-materials records are complete:
#   - every distributed binary or data artifact (everything in MANIFEST.sha256) and every
#     embedded third-party library has a provenance row with an origin (source and pinned
#     revision), a checksum, a licence, a licence check status and a corresponding-source
#     disposition (source_disposition.psv, which points into corresponding_source.psv);
#   - every image-component row (software in the image that is not an apk package, such as
#     jemalloc) has a source and a licence field, and the jemalloc row is fully filled in;
#   - the header no longer says the inventory is known to be incomplete, and the prose
#     records name jemalloc;
#   - tools/generate_sbom.sh really cross-checks the SBOM against the provenance record, shown
#     on small fixtures: a provenance row the SBOM omits, an image component with no row, a
#     changed checksum, an unclassified file and a preload setting each make it exit 2;
#   - the generator hashes the files under /opt/halow/artifacts in the image and compares them with
#     the provenance artifact rows in both directions (an omitted row, a stale checksum, a file
#     in the image with no row, a row with no file and a disagreeing image MANIFEST.sha256 each
#     exit 2); it checks the embedded: rows against a fixed expected set and byte-string markers
#     in the carrier files; it reads tempio, the s6 family, bashio and the CA bundle checksums
#     from the image and compares them (a stale or missing one exits 2);
#   - the SBOM properties, licence names, bom-refs and licences-summary.txt agree with the
#     provenance rows;
#   - when the staged executables are present, neither contains jemalloc.
# Limits: the fixtures prove the cross-check mechanism; they do not read a real image. Run
# tools/generate_sbom.sh on the final image (it exits 2 on any mismatch), or set
# HALOW_SBOM_DIR to a directory it wrote to have this test re-run the cross-check on it.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
. tests/test_helpers.sh

PSV="provenance.psv"
MAN="MANIFEST.sha256"
DISP="source_disposition.psv"
CSV="corresponding_source.psv"
GEN="tools/generate_sbom.sh"

echo "== test_sbom_completeness =="
assert_file_exists "$PSV" "the provenance record exists"
assert_file_exists "$DISP" "the corresponding-source disposition record exists"
assert_file_exists "$GEN" "the SBOM generator exists"

rows="$(grep -v -E '^[[:space:]]*(#|$)' "$PSV")"
field() { awk -F'|' -v i="$2" '{gsub(/^[ \t]+|[ \t]+$/, "", $i); print $i}' <<< "$1"; }
prow() { printf '%s\n' "$rows" | awk -F'|' -v k="$1" '{x=$1; gsub(/^[ \t]+|[ \t]+$/, "", x); if (x == k) print $0}'; }
drows="$(grep -v -E '^[[:space:]]*(#|$)' "$DISP")"
csv_ids="$(grep -v -E '^[[:space:]]*(#|$)' "$CSV" | awk -F'|' '{x=$1; gsub(/^[ \t]+|[ \t]+$/, "", x); print x}')"
# the disposition row for a provenance path: the exact path, else the wildcard of its kind
drow_for() {
    local p="$1" r
    r="$(printf '%s\n' "$drows" | awk -F'|' -v k="$p" '{x=$1; gsub(/^[ \t]+|[ \t]+$/, "", x); if (x == k) print $0}')"
    if [ -z "$r" ]; then
        local kind="${p%%:*}"
        r="$(printf '%s\n' "$drows" | awk -F'|' -v k="${kind}:*" '{x=$1; gsub(/^[ \t]+|[ \t]+$/, "", x); if (x == k) print $0}')"
    fi
    printf '%s\n' "$r"
}

echo "-- the disposition record is well formed --"
bad=0
while IFS= read -r r; do
    [ -n "$r" ] || continue
    n="$(awk -F'|' '{print NF}' <<< "$r")"
    [ "$n" -eq 4 ] || { bad=1; echo "    row with $n fields: ${r%%|*}"; continue; }
    for i in 1 2 3 4; do [ -n "$(field "$r" "$i")" ] || { bad=1; echo "    empty field $i in ${r%%|*}"; }; done
    d="$(field "$r" 2)"; id="$(field "$r" 3)"
    case "$d" in
        source-recorded) printf '%s\n' "$csv_ids" | grep -qx -- "$id" || { bad=1; echo "    ${r%%|*}: id '$id' is not a row of $CSV"; } ;;
        source-asset) grep -v -E '^[[:space:]]*(#|$)' source-assets/ASSETS.psv | awk -F'|' '{x=$1; gsub(/^[ \t]+|[ \t]+$/, "", x); print x}' | grep -qx -- "$id" || { bad=1; echo "    ${r%%|*}: id '$id' is not an asset of source-assets/ASSETS.psv"; } ;;
        binary-only-no-source-record|upstream-reference-only) [ "$id" = "none" ] || { bad=1; echo "    ${r%%|*}: id must be none for $d"; } ;;
        *) bad=1; echo "    ${r%%|*}: unknown disposition '$d'" ;;
    esac
done <<< "$drows"
assert_eq "0" "$bad" "every disposition row has four fields, a known disposition, and a real corresponding-source id where it claims one"

echo "-- every distributed artifact has origin, revision, checksum, licence, check status and a disposition --"
bad=0
n_art=0
while read -r sha path; do
    [ -n "$sha" ] || continue
    n_art=$((n_art + 1))
    r="$(prow "$path")"
    if [ -z "$r" ]; then bad=1; echo "    $path: no provenance row"; continue; fi
    [ "$(field "$r" 2)" = "$sha" ] || { bad=1; echo "    $path: provenance checksum differs from the manifest"; }
    [[ "$(field "$r" 2)" =~ ^[0-9a-f]{64}$ ]] || { bad=1; echo "    $path: checksum is not 64 hex digits"; }
    for i in 3 4 5 6 7 8; do
        v="$(field "$r" "$i")"
        case "$v" in ''|'not recorded'*|none|'-') bad=1; echo "    $path: field $i is empty or not recorded"; ;; esac
    done
    [[ "$(field "$r" 5)" =~ [0-9a-f]{40} ]] || { bad=1; echo "    $path: no 40-digit commit in the pinned ref"; }
    case "$(field "$r" 8)" in confirmed|apkbuild-confirmed|from-bundle-record|unverified) ;; *) bad=1; echo "    $path: bad licence_check" ;; esac
    [ -n "$(drow_for "$path")" ] || { bad=1; echo "    $path: no corresponding-source disposition"; }
done < <(grep -v -E '^[[:space:]]*(#|$)' "$MAN")
assert_eq "0" "$bad" "each of the $n_art manifest artifacts is fully described"
assert_eq "7" "$n_art" "the manifest lists seven artifacts"

echo "-- every embedded third-party library has origin, revision, licence, check status and a disposition --"
bad=0; n_emb=0
while IFS= read -r p; do
    case "$p" in embedded:*) ;; *) continue ;; esac
    n_emb=$((n_emb + 1))
    r="$(prow "$p")"
    for i in 3 4 5 6 7 8; do
        v="$(field "$r" "$i")"
        case "$v" in ''|'not recorded'*|none|'-') bad=1; echo "    $p: field $i is empty or not recorded" ;; esac
    done
    [ -n "$(drow_for "$p")" ] || { bad=1; echo "    $p: no corresponding-source disposition"; }
done < <(awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $1); print $1}' <<< "$rows")
assert_eq "0" "$bad" "each of the $n_emb embedded libraries is fully described"
assert_eq "5" "$n_emb" "there are five embedded libraries (OpenSSL, glibc, libnl, libgcc, rate control)"

echo "-- every image-component row has a source and a licence field --"
bad=0; n_img=0
while IFS= read -r p; do
    case "$p" in image-component:*) ;; *) continue ;; esac
    n_img=$((n_img + 1))
    r="$(prow "$p")"
    for i in 3 4 5 6 7; do
        v="$(field "$r" "$i")"
        case "$v" in ''|'-') bad=1; echo "    $p: field $i is empty" ;; esac
    done
    [ -n "$(drow_for "$p")" ] || { bad=1; echo "    $p: no corresponding-source disposition"; }
done < <(awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $1); print $1}' <<< "$rows")
assert_eq "0" "$bad" "each of the $n_img image-component rows has a source, a pinned ref, a licence, a licence text and a disposition"

echo "-- jemalloc (built from source by the base image, not an apk package) is recorded in full --"
j="$(prow image-component:jemalloc)"
assert_success "there is an image-component:jemalloc row" test -n "$j"
assert_success "the row's checksum is the SHA-256 of the library" bash -c '[[ "$1" =~ ^[0-9a-f]{64}$ ]]' _ "$(field "$j" 2)"
assert_success "the row names a version" bash -c '[[ "$1" =~ jemalloc\ [0-9]+\.[0-9]+\.[0-9]+ ]]' _ "$(field "$j" 3)"
assert_success "the row names an https source" bash -c '[[ "$1" == *https://github.com/jemalloc/jemalloc* ]]' _ "$(field "$j" 4)"
assert_success "the row pins a tag and a 40-digit commit" bash -c '[[ "$1" =~ ^version\ [0-9.]+\ \(tag\ [0-9.]+,\ commit\ [0-9a-f]{40}\) ]]' _ "$(field "$j" 5)"
assert_success "the row records the source tarball checksum" bash -c '[[ "$1" =~ SHA-256\ [0-9a-f]{64} ]]' _ "$(field "$j" 4)"
assert_success "the row says what the licence text is (name or the absence of one)" bash -c '[ -n "$1" ] && [[ "$1" == *COPYING* ]]' _ "$(field "$j" 6)$(field "$j" 7)"
assert_success "the row records its relationship to the add-on's programs (nothing links it)" bash -c '[[ "$1" == *"no ELF file in the image lists libjemalloc"* && "$1" == *"statically linked"* ]]' _ "$(field "$j" 10)"
assert_eq "approved" "$(field "$j" 9)" "redistribution of jemalloc is approved"
assert_eq "upstream-reference-only" "$(field "$(drow_for image-component:jemalloc)" 2)" "jemalloc has a corresponding-source disposition"

echo "-- the header no longer says the inventory is incomplete --"
assert_failure "provenance.psv has no 'Known and not yet corrected' note" grep -q 'Known and not yet corrected' "$PSV"
assert_failure "provenance.psv does not say the inventory is not yet complete" grep -q 'is not yet complete' "$PSV"
assert_success "provenance.psv header names jemalloc and the audit" bash -c 'grep -q "^# Completeness of the image rows" "$1" && grep -q "image-component:jemalloc" "$1"' _ "$PSV"

echo "-- the prose records agree with the rows --"
n_prog=$(( n_img - 4 ))   # minus base-image, addon-own-code, base-image-config, ca-bundle (a data file, not a program)
assert_success "PROVENANCE.md says $n_prog programs are installed outside apk" grep -q "$n_prog programs installed outside apk" PROVENANCE.md
assert_success "PROVENANCE.md names jemalloc in the image inventory and has a licence summary table" bash -c 'grep -q "jemalloc" "$1" && grep -q "Licence summary of the image components" "$1"' _ PROVENANCE.md
assert_success "PROVENANCE.md says the version of jemalloc is inferred, not stated by the image" grep -q -i "jemalloc.*not stated by the image\|inferred from the base image" PROVENANCE.md
assert_success "SOURCE-OFFER.md names jemalloc among the components whose source is not included" grep -q "jemalloc" SOURCE-OFFER.md
assert_success "SOURCE-OFFER.md points to provenance.psv for the full-image inventory" grep -q "provenance.psv" SOURCE-OFFER.md
assert_success "source_disposition.psv says it is not a legal conclusion" grep -q -i 'not a legal conclusion' "$DISP"
assert_failure "none of the changed records uses an em dash" grep -q "$(printf '\xe2\x80\x94')" "$PSV" "$DISP" "$GEN"

echo "-- the generator cross-checks the SBOM against the provenance record --"
assert_success "generate_sbom.sh has valid syntax" bash -n "$GEN"
for needle in 'jemalloc-config --version' 'image-files.txt' 'unowned-files.txt' 'provenance-coverage.txt' 'HALOW_PROVENANCE' '--from-dir' 'LD_PRELOAD' 'exits with status 2' 'image-artifacts.sha256' 'EXPECTED_EMBEDDED' 'tree-sha256' 'embedded-evidence.txt'; do
    assert_success "generate_sbom.sh mentions $needle" grep -q -F -- "$needle" "$GEN"
done

# ---- fixtures ----
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
H64="b0454c6af4498f9fd5b775c6674c5fa7dc4257ee8b1cdf1debfc5a030614a7fb"
OTHER64="1111111111111111111111111111111111111111111111111111111111111111"
LONGLIC="the text of COPYING in jemalloc 5.4.0 (two numbered conditions and a warranty disclaimer; the text names no licence and carries no SPDX identifier); jeprof carries its own notice text"
T_S6="aaaa000000000000000000000000000000000000000000000000000000000001"
T_BASHIO="aaaa000000000000000000000000000000000000000000000000000000000002"
F_TEMPIO="aaaa000000000000000000000000000000000000000000000000000000000003"
F_CA="aaaa000000000000000000000000000000000000000000000000000000000004"
F_PIP="aaaa000000000000000000000000000000000000000000000000000000000005"
mkfix() { # mkfix <dir>: a small consistent fixture (provenance + intermediate files)
    local d="$1"; mkdir -p "$d"
    cat > "$d/prov.psv" <<EOF
# fixture provenance
./a.bin | $OTHER64 | Fixture program | https://example.invalid/a | aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa | MIT | LICENSE | confirmed | approved | note
embedded:openssl | not-applicable | Fixture openssl | https://example.invalid/lib | tag 1.0 | MIT | LICENSE | unverified | approved | note
embedded:glibc | not-applicable | Fixture glibc | https://example.invalid/lib | tag 1.0 | MIT | LICENSE | unverified | approved | note
embedded:libnl | not-applicable | Fixture libnl | https://example.invalid/lib | tag 1.0 | MIT | LICENSE | unverified | approved | note
embedded:libgcc | not-applicable | Fixture libgcc | https://example.invalid/lib | tag 1.0 | MIT | LICENSE | unverified | approved | note
embedded:mmrc | not-applicable | Fixture mmrc | https://example.invalid/lib | tag 1.0 | MIT | LICENSE | unverified | approved | note
image-package:foo | not-applicable | foo 1.0-r0 (Alpine package) | https://example.invalid/foo | commit abc | MIT | none installed | unverified | approved | note
image-component:base-image | $OTHER64 | Fixture base image | https://example.invalid/base | digest | composite | none | unverified | approved | note
image-component:addon-own-code | not-applicable | Fixture own code | this repository | none | none | none | unverified | approved | note
image-component:s6 | $T_S6 | s6 2.15.1.0 | https://example.invalid/s6 | version 2.15.1.0 | not recorded in the image | none | unverified | approved | note
image-component:tempio | $F_TEMPIO | tempio 2026.07.0 | https://example.invalid/tempio | version 2026.07.0 | not recorded in the image | none | unverified | approved | note
image-component:bashio | $T_BASHIO | bashio 0.19.0 | https://example.invalid/bashio | version 0.19.0 (inferred) | not recorded in the image | none | unverified | approved | note
image-component:jemalloc | $H64 | jemalloc 5.4.0 | https://example.invalid/jemalloc | version 5.4.0 (tag 5.4.0, commit 7a34f18502e7b222724097cdcd499b437d189acc) | $LONGLIC | COPYING | confirmed | approved | note
image-component:base-image-config | $F_PIP | /etc/pip.conf | https://example.invalid/pip | tag 1 | Apache-2.0 at repository level (the LICENSE file of that repository at that commit is the Apache text; the file itself has no licence header) | LICENSE | confirmed | approved | note
image-component:ca-bundle | $F_CA | CA bundle | https://example.invalid/ca | Alpine package | MPL-2.0 AND MIT (apk metadata; unverified) | none | unverified | approved | note
EOF
    cat > "$d/image-info.txt" <<EOF
image reference:   fixture
image id:          sha256:fixture
base image (from the build label): fixture
VERSION_ID=3.23.7
-- image environment (Config.Env) --
ENV: PATH=/usr/bin
ENV: LANG=C.UTF-8
-- /etc/ld.so.preload --
absent
EOF
    printf '# header\nfoo | 1.0-r0 | aarch64 | foo | MIT | https://example.invalid/foo | abc | Q1x | none\n' > "$d/apk-packages.psv"
    cat > "$d/non-apk-components.psv" <<EOF
# header
s6 | 2.15.1.0 | /package/admin/s6-2.15.1.0 | not recorded | note tree-sha256=$T_S6 over 2 regular file(s) under: package/admin/s6-2.15.1.0
tempio | 2026.07.0 | /usr/bin/tempio | not recorded | note sha256=$F_TEMPIO
bashio | not recorded | /usr/lib/bashio and /usr/bin/bashio | not recorded | note tree-sha256=$T_BASHIO over 3 regular file(s) under: usr/lib/bashio
jemalloc | not stated in the image | /usr/local/lib/libjemalloc.so.2 | not recorded | note sha256=$H64
base-image-config | not applicable | /etc/pip.conf | not recorded | note sha256=$F_PIP
ca-bundle | not applicable | /etc/ssl/certs/ca-certificates.crt | not recorded | note sha256=$F_CA; 10 bytes
EOF
    printf 'C:Q1x\nP:foo\nV:1.0-r0\nA:aarch64\nF:usr/bin\nR:foo\n\n' > "$d/apk-installed.db"
    printf 'f /usr/bin/foo\nf /usr/local/lib/libjemalloc.so.2\nl /usr/local/lib/libjemalloc.so libjemalloc.so.2\nf /opt/halow/artifacts/a.bin\nl /bin/ls /bin/busybox\n' > "$d/image-files.txt"
    : > "$d/jemalloc-references.txt"
    printf '%s  ./a.bin\n' "$OTHER64" > "$d/image-artifacts.sha256"
    cp "$d/image-artifacts.sha256" "$d/image-artifacts-manifest.sha256"
    cat > "$d/embedded-evidence.txt" <<EOF
# embedded library | carrier file | marker string | lines
embedded:openssl | hostapd_s1g | /usr/local/ssl | 5
embedded:glibc | hostapd_s1g | GLIBC | 7
embedded:libgcc | hostapd_s1g | GCC: (Buildroot) 13.4.0 | 1
embedded:mmrc | morse.ko | MMRC_BW_1MHZ | 30
EOF
}
runfix() { # runfix <dir>
    HALOW_PROVENANCE="$1/prov.psv" bash "$GEN" --from-dir "$1" > "$1/run.log" 2>&1
}

d="$TMP/ok"; mkfix "$d"
assert_exit 0 "consistent fixture: the cross-check passes" runfix "$d"
assert_success "the SBOM has the jemalloc component with the version taken from the provenance row" python3 -I -c '
import json,sys
b=json.load(open(sys.argv[1]+"/sbom.cdx.json"))
c=[x for x in b["components"] if x["name"]=="jemalloc"]
assert len(c)==1 and c[0]["version"]=="5.4.0", c
assert c[0]["hashes"][0]["content"]==sys.argv[2]
props={p["name"]:p["value"] for p in c[0]["properties"]}
assert props["halow:source"].startswith("https://") and props["halow:licence-text"]=="COPYING"
' "$d" "$H64"
assert_success "the SBOM has one component for every provenance row" python3 -I -c '
import json,sys
b=json.load(open(sys.argv[1]+"/sbom.cdx.json"))
refs={p["value"] for c in b["components"] for p in c.get("properties",[]) if p["name"]=="halow:provenance-row"}
refs|={"artifact:"+c["bom-ref"][9:] for c in b["components"] if c["bom-ref"].startswith("artifact:")}
need={"image-package:foo","image-component:base-image","image-component:addon-own-code","image-component:s6","image-component:jemalloc","image-component:tempio","image-component:bashio","image-component:ca-bundle","artifact:./a.bin","artifact:embedded:openssl","artifact:embedded:mmrc"}
assert need<=refs, need-refs
' "$d"
assert_success "the coverage file says complete" grep -q '^result: complete' "$d/provenance-coverage.txt"

d="$TMP/no-row"; mkfix "$d"; grep -v '^image-component:jemalloc ' "$d/prov.psv" > "$d/p" && mv "$d/p" "$d/prov.psv"
assert_exit 2 "an image component with no provenance row fails the cross-check" runfix "$d"
assert_success "...and the finding names jemalloc" grep -q 'FINDING: non-apk component jemalloc' "$d/provenance-coverage.txt"

d="$TMP/ghost"; mkfix "$d"; echo "image-component:ghost | not-applicable | Ghost | https://example.invalid/g | version 1 | MIT | none | unverified | approved | note" >> "$d/prov.psv"
assert_exit 2 "a provenance row that the SBOM omits fails the cross-check" runfix "$d"
assert_success "...and the finding names the row" grep -q 'FINDING: provenance row image-component:ghost has no component' "$d/provenance-coverage.txt"

d="$TMP/pkg"; mkfix "$d"; printf 'bar | 2.0-r0 | aarch64 | bar | MIT | https://example.invalid/bar | def | Q1y | none\n' >> "$d/apk-packages.psv"
assert_exit 2 "an installed package with no provenance row fails the cross-check" runfix "$d"

d="$TMP/pkgver"; mkfix "$d"; sed -i 's/^foo | 1.0-r0/foo | 1.1-r0/' "$d/apk-packages.psv"
assert_exit 2 "an installed package whose version differs from its row fails the cross-check" runfix "$d"

d="$TMP/hash"; mkfix "$d"; sed -i "s/sha256=$H64/sha256=$OTHER64/" "$d/non-apk-components.psv"
assert_exit 2 "a library whose checksum differs from its row fails the cross-check" runfix "$d"
assert_success "...and the finding names the checksums" grep -q 'FINDING: non-apk component jemalloc: the file in the image has SHA-256' "$d/provenance-coverage.txt"

d="$TMP/unclassified"; mkfix "$d"; echo 'f /usr/local/bin/mystery-tool' >> "$d/image-files.txt"
assert_exit 2 "a file that no package owns and no group claims fails the cross-check" runfix "$d"
assert_success "...and it is listed as UNCLASSIFIED" grep -q 'mystery-tool' "$d/unowned-files.txt"

d="$TMP/preload"; mkfix "$d"; sed -i 's|^ENV: LANG=C.UTF-8|ENV: LD_PRELOAD=/usr/local/lib/libjemalloc.so.2|' "$d/image-info.txt"
assert_exit 2 "an LD_PRELOAD in the image environment fails the cross-check" runfix "$d"

d="$TMP/ref"; mkfix "$d"; echo '/usr/bin/python3.12' > "$d/jemalloc-references.txt"
assert_exit 2 "a program outside /usr/local that names libjemalloc fails the cross-check" runfix "$d"

echo "-- the SBOM output agrees with the provenance rows (properties, licence names, references, summary) --"
d="$TMP/ok"
assert_success "jemalloc: no stale 'not recorded' licence property, a short neutral licence name, the description in a property, the version marked as inferred" python3 -I -c '
import json,sys
b=json.load(open(sys.argv[1]+"/sbom.cdx.json"))
c=[x for x in b["components"] if x["name"]=="jemalloc"][0]
props={p["name"]:p["value"] for p in c["properties"]}
assert "halow:licence" not in props and "not recorded" not in json.dumps(c["properties"]), props
assert "licence not checked" not in json.dumps(c["properties"])
assert c["licenses"][0]["license"]["name"]=="see COPYING text (no licence named by the text)", c["licenses"]
assert len(c["licenses"][0]["license"]["name"])<80
assert props["halow:licence-description"].startswith("the text of COPYING in jemalloc 5.4.0"), props
assert props["halow:licence-check"]=="confirmed" and props["halow:redistribution"]=="approved"
assert "inferred" in props["halow:version-source"]
' "$d"
assert_success "base-image-config: no 'not applicable' version, no space in any bom-ref, short licence name, properties from the row" python3 -I -c '
import json,sys
b=json.load(open(sys.argv[1]+"/sbom.cdx.json"))
c=[x for x in b["components"] if x["name"]=="base-image-config"][0]
assert "version" not in c, c
assert c["bom-ref"]=="base:base-image-config", c["bom-ref"]
assert all(" " not in x["bom-ref"] for x in b["components"]), [x["bom-ref"] for x in b["components"] if " " in x["bom-ref"]]
assert len(set(x["bom-ref"] for x in b["components"]))==len(b["components"])
assert len(c["licenses"][0]["license"]["name"])<80
props={p["name"]:p["value"] for p in c["properties"]}
assert props["halow:licence-check"]=="confirmed" and props["halow:provenance-row"]=="image-component:base-image-config"
assert "not applicable" not in json.dumps(c)
' "$d"
assert_success "tempio and the CA bundle carry their measured file SHA-256; s6 and bashio carry a tree digest property and no file hash" python3 -I -c '
import json,sys
b=json.load(open(sys.argv[1]+"/sbom.cdx.json"))
by={x["name"]:x for x in b["components"]}
assert by["tempio"]["hashes"][0]["content"]==sys.argv[2]
assert by["ca-bundle"]["hashes"][0]["content"]==sys.argv[3] and by["ca-bundle"]["type"]=="data"
for n,v in (("s6",sys.argv[4]),("bashio",sys.argv[5])):
    assert "hashes" not in by[n], n
    props={p["name"]:p["value"] for p in by[n]["properties"]}
    assert props["halow:tree-sha256"]==v, n
assert by["bashio"]["version"]=="0.19.0"
' "$d" "$F_TEMPIO" "$F_CA" "$T_S6" "$T_BASHIO"
assert_success "the artifact component carries the checksum measured in the image" python3 -I -c '
import json,sys
b=json.load(open(sys.argv[1]+"/sbom.cdx.json"))
c=[x for x in b["components"] if x["bom-ref"]=="artifact:./a.bin"][0]
assert c["hashes"][0]["content"]==sys.argv[2]
' "$d" "$OTHER64"
assert_success "licences-summary.txt shows the bashio version from the provenance row, marked as inferred" grep -q '^bashio 0.19.0 (inferred' "$d/licences-summary.txt"
assert_failure "licences-summary.txt no longer shows bashio as 'not recorded'" grep -q '^bashio not recorded' "$d/licences-summary.txt"
assert_success "licences-summary.txt shows the jemalloc version, marked as inferred" grep -q '^jemalloc 5.4.0 (inferred' "$d/licences-summary.txt"
assert_success "the coverage file notes what cannot be verified for the embedded libraries" grep -q 'embedded:libnl cannot be verified from the image' "$d/provenance-coverage.txt"

echo "-- the artifacts in the image are measured and cross-checked with the provenance rows --"
d="$TMP/art-omitted"; mkfix "$d"; grep -v '^\./a.bin ' "$d/prov.psv" > "$d/p" && mv "$d/p" "$d/prov.psv"
assert_exit 2 "an artifact row omitted from provenance (file present in the image) fails the cross-check" runfix "$d"
assert_success "...and the finding names the artifact" grep -q 'FINDING: artifact ./a.bin is in the image' "$d/provenance-coverage.txt"

d="$TMP/art-stale"; mkfix "$d"; sed -i "s/^$OTHER64/$H64/" "$d/image-artifacts.sha256"
assert_exit 2 "a stale artifact checksum (the file in the image differs from the row) fails the cross-check" runfix "$d"
assert_success "...and the finding says stale" grep -q 'FINDING: artifact ./a.bin: the file in the image has SHA-256 .* (stale)' "$d/provenance-coverage.txt"

d="$TMP/art-extra"; mkfix "$d"; printf '%s  ./b.bin\n' "$H64" | tee -a "$d/image-artifacts.sha256" >> "$d/image-artifacts-manifest.sha256"
assert_exit 2 "an artifact present in the image but absent from provenance fails the cross-check" runfix "$d"
assert_success "...and the finding names it" grep -q 'FINDING: artifact ./b.bin is in the image' "$d/provenance-coverage.txt"

d="$TMP/art-nofile"; mkfix "$d"; echo "./c.bin | $H64 | Ghost artifact | https://example.invalid/c | cccccccccccccccccccccccccccccccccccccccc | MIT | LICENSE | confirmed | approved | note" >> "$d/prov.psv"
assert_exit 2 "an artifact row with no file in the image fails the cross-check" runfix "$d"
assert_success "...and the finding names the row" grep -q 'FINDING: provenance row ./c.bin has no file under /opt/halow/artifacts' "$d/provenance-coverage.txt"

d="$TMP/art-manifest"; mkfix "$d"; sed -i "s/^$OTHER64/$H64/" "$d/image-artifacts-manifest.sha256"
assert_exit 2 "the image's own MANIFEST.sha256 disagreeing with the file fails the cross-check" runfix "$d"
assert_success "...and the finding names the manifest" grep -q "FINDING: the image's MANIFEST.sha256 says" "$d/provenance-coverage.txt"

d="$TMP/art-unmeasured"; mkfix "$d"; rm "$d/image-artifacts.sha256"
assert_exit 2 "artifacts that were not measured in the image fail the cross-check (fail closed)" runfix "$d"

echo "-- the embedded libraries: the expected set, and the evidence in the carriers --"
d="$TMP/emb-omitted"; mkfix "$d"; grep -v '^embedded:openssl ' "$d/prov.psv" > "$d/p" && mv "$d/p" "$d/prov.psv"
assert_exit 2 "an embedded library row omitted from provenance fails the cross-check" runfix "$d"
assert_success "...and the finding names it" grep -q 'FINDING: expected embedded library row embedded:openssl is missing' "$d/provenance-coverage.txt"

d="$TMP/emb-extra"; mkfix "$d"; echo "embedded:zlib | not-applicable | Fixture zlib | https://example.invalid/z | tag 1 | Zlib | LICENSE | unverified | approved | note" >> "$d/prov.psv"
assert_exit 2 "an embedded row the generator does not expect fails the cross-check" runfix "$d"

d="$TMP/emb-marker"; mkfix "$d"; sed -i 's/| MMRC_BW_1MHZ | 30/| MMRC_BW_1MHZ | 0/' "$d/embedded-evidence.txt"
assert_exit 2 "a marker that is absent from the carrier file in the image fails the cross-check" runfix "$d"
assert_success "...and the finding names the library" grep -q "FINDING: embedded:mmrc: the marker 'MMRC_BW_1MHZ' was not found in morse.ko" "$d/provenance-coverage.txt"

d="$TMP/emb-noevidence"; mkfix "$d"; rm "$d/embedded-evidence.txt"
assert_exit 2 "no embedded-library evidence fails the cross-check (fail closed)" runfix "$d"

echo "-- the facts that the image holds are read from it and compared: tempio, s6 family, bashio, CA bundle --"
d="$TMP/tempio-stale"; mkfix "$d"; sed -i "s/^\(image-component:tempio | \)$F_TEMPIO/\1$OTHER64/" "$d/prov.psv"
assert_exit 2 "a stale tempio checksum in the provenance row fails the cross-check" runfix "$d"
assert_success "...and the finding names tempio" grep -q 'FINDING: non-apk component tempio: the file in the image has SHA-256' "$d/provenance-coverage.txt"

d="$TMP/bashio-stale"; mkfix "$d"; sed -i "s/^\(image-component:bashio | \)$T_BASHIO/\1$OTHER64/" "$d/prov.psv"
assert_exit 2 "a stale bashio tree digest in the provenance row fails the cross-check" runfix "$d"
assert_success "...and the finding says tree" grep -q 'FINDING: non-apk component bashio: the tree in the image has SHA-256' "$d/provenance-coverage.txt"

d="$TMP/s6-stale"; mkfix "$d"; sed -i "s/tree-sha256=$T_S6/tree-sha256=$OTHER64/" "$d/non-apk-components.psv"
assert_exit 2 "a changed s6 tree in the image (digest differs from the row) fails the cross-check" runfix "$d"
assert_success "...and the finding names s6" grep -q 'FINDING: non-apk component s6: the tree in the image has SHA-256' "$d/provenance-coverage.txt"

d="$TMP/tempio-none"; mkfix "$d"; sed -i "s/^\(image-component:tempio | \)$F_TEMPIO/\1not-applicable/" "$d/prov.psv"
assert_exit 2 "a measured checksum that the provenance row does not record fails the cross-check" runfix "$d"

d="$TMP/ca-stale"; mkfix "$d"; sed -i "s/^\(image-component:ca-bundle | \)$F_CA/\1$OTHER64/" "$d/prov.psv"
assert_exit 2 "a stale CA bundle checksum fails the cross-check" runfix "$d"

d="$TMP/ca-norow"; mkfix "$d"; grep -v '^image-component:ca-bundle ' "$d/prov.psv" > "$d/p" && mv "$d/p" "$d/prov.psv"
assert_exit 2 "a CA bundle in the image with no provenance row fails the cross-check" runfix "$d"

echo "-- the real provenance record carries the measured facts and the upstream references --"
for k in s6 s6-overlay s6-overlay-helpers s6-linux-init s6-linux-utils s6-portable-utils s6-rc s6-networking s6-dns skalibs execline bashio tempio ca-bundle; do
    r="$(prow "image-component:$k")"
    assert_success "image-component:$k records a 64-digit checksum or tree digest in field 2" bash -c '[[ "$1" =~ ^[0-9a-f]{64}$ ]]' _ "$(field "$r" 2)"
done
assert_failure "no s6 row still says the upstream location is not recorded" grep -q 'upstream location not recorded' "$PSV"
assert_success "the s6 rows name the release URL of the base image build file" bash -c '[ "$(grep -c "releases/download/v3.2.3.2/" "$1")" -ge 11 ]' _ "$PSV"
assert_success "the s6-overlay row records the four upstream tarball checksums as published" bash -c 'r="$(grep "^image-component:s6-overlay |" "$1")"; for h in 5379750ed30a84bbd2e2dd74847ba6b5bd29cd0b2e3ea2ec58049b57eb2eda12 b17f17a82e7a515c682a91edaf2ffdabb73f891981b6c1fd712115693a2f8b4c 6251226709efc0c88800a8c140404d93b391e1b4051ef50fa0e8aac1fdcf738c a215675c375aca9efecde3065df22b19fb8dcdc1362566931c6b5e778099a0fb; do [[ "$r" == *$h* ]] || exit 1; done' _ "$PSV"
assert_success "the tempio row records its release URL and the pinned upstream version" bash -c 'r="$(grep "^image-component:tempio |" "$1")"; [[ "$r" == *releases/download/2026.07.0/tempio_aarch64* && "$r" == *TEMPIO_VERSION* ]]' _ "$PSV"
assert_success "the bashio row records the pinned upstream version as inferred and no upstream checksum" bash -c 'r="$(grep "^image-component:bashio |" "$1")"; [[ "$r" == *BASHIO_VERSION* && "$r" == *inferred* && "$r" == *"(not recorded)"* ]]' _ "$PSV"
c="$(prow image-component:ca-bundle)"
assert_success "the CA bundle row is a data file of the apk package ca-certificates-bundle with size, licence as recorded, redistribution approved and source disposition none held" bash -c '[[ "$1" == *178791* && "$1" == *ca-certificates-bundle* && "$1" == *"Source disposition: none held"* && "$1" == *"MPL-2.0 AND MIT"* && "$1" == *approved* ]]' _ "$c"
assert_eq "0" "$(grep '^image-package:' "$PSV" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' | grep -c -v -x 'not-applicable')" "apk package rows carry no sha256 (the apk database checksum is not a SHA-256)"
assert_success "PROVENANCE.md says that the apk database checksum is not a SHA-256 and apk rows carry no sha256" bash -c 'grep -q "not a SHA-256" "$1" && grep -q -i "no sha256" "$1"' _ PROVENANCE.md

echo "-- the real record, against a generated SBOM directory when one is given --"
if [ -n "${HALOW_SBOM_DIR:-}" ] && [ -d "$HALOW_SBOM_DIR" ]; then
    assert_exit 0 "the cross-check passes for the real provenance record and $HALOW_SBOM_DIR" bash "$GEN" --from-dir "$HALOW_SBOM_DIR"
else
    echo "  SKIP: HALOW_SBOM_DIR is not set; the real-image cross-check (1 assertion) was not run (run tools/generate_sbom.sh on the final image)"; HALOW_SKIPPED=1
fi

echo "-- the staged executables contain no jemalloc, when they are staged --"
if [ -f artifacts/hostapd_s1g ]; then
    for f in hostapd_s1g hostapd_cli_s1g; do
        assert_eq "0" "$(grep -c -a -i jemalloc "artifacts/$f")" "artifacts/$f contains no jemalloc"
    done
else
    echo "  SKIP: artifacts/ is not staged here; the staged-binary checks (2 assertions) were not run (run build.sh first)"; HALOW_SKIPPED=$(( ${HALOW_SKIPPED:-0} + 2 ))
fi

echo "test_sbom_completeness: $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed, ${HALOW_SKIPPED:-0} assertions skipped"
exit $([ "$HALOW_TEST_FAILURES" -eq 0 ] && echo 0 || echo 1)
