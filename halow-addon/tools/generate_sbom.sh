#!/usr/bin/env bash
# Software bill of materials (SBOM) of the access point add-on image. Off-device only.
#
# Reads an already built image (the one build.sh builds, morse-micro-halow-ap:local by default),
# without changing it, and writes into an output directory that must NOT be inside this
# repository's tracked tree (the default is a directory under ${TMPDIR:-/tmp}; pass an
# explicit directory if you want it elsewhere, and keep the result out of commits unless it
# is reviewed):
#
#   image-info.txt         image id, architecture, labels, base image reference, release file,
#                          apk repositories and world file
#   apk-packages.psv       one row per installed Alpine package: name | version | arch |
#                          origin | licence (as recorded by apk) | homepage | aports build
#                          commit | apk database checksum | licence files found in the image
#   non-apk-components.psv programs and files the base image installs outside apk (s6-overlay and
#                          its parts, tempio, bashio, jemalloc, the base image's pip.conf, the
#                          generated CA bundle): version where the image states it (jemalloc and
#                          bashio do not; the version then comes from the matching
#                          image-component row of provenance.psv and is shown as inferred), plus
#                          the checksum measured in the image: sha256= for one file (tempio,
#                          jemalloc, pip.conf, the CA bundle) or tree-sha256= for a tree (each
#                          s6 part, bashio)
#   image-artifacts.sha256 sha256 of every file under /opt/halow/artifacts in the image, measured
#                          here (MANIFEST.sha256 excluded); image-artifacts-manifest.sha256 is a
#                          copy of the image's own MANIFEST.sha256
#   embedded-evidence.txt  for each statically linked third-party library the byte-string markers
#                          found in the carrier file in the image (see "Embedded libraries")
#   image-files.txt        every regular file and symlink in the image (type, path, link target)
#   unowned-files.txt      the files no apk package owns, each with the group it belongs to; any
#                          file that fits no known group is listed as UNCLASSIFIED
#   jemalloc-references.txt files in the image whose bytes contain the name libjemalloc
#   provenance-coverage.txt the cross-check between provenance.psv and this SBOM (see below)
#   artifacts.psv          the bundled artifacts and embedded libraries, from provenance.psv (their
#                          files and checksums are cross-checked against the image, see below)
#   licences-summary.txt   distinct licence strings with package counts, packages whose
#                          licence text is not in the image, and the unverified items
#   sbom.cdx.json          the same inventory as a CycloneDX 1.5 JSON document
#
# What this is NOT: it does not verify any licence. Every licence string for an Alpine
# package is what the package's own metadata says; it was not compared with upstream source
# here. It is not a legal conclusion and not permission to redistribute anything. Nothing is
# pushed or published; the script only runs the local image with the network disabled.
#
# Completeness cross-check. After the files are written the script compares them with
# provenance.psv in both directions and writes provenance-coverage.txt:
#   - every provenance row must appear in the SBOM (an artifact, an embedded library, an image
#     package, an image component), and every SBOM component must have a provenance row;
#   - an image package's version and a non-apk component's version and checksum must agree with
#     its provenance row; a checksum measured in the image must be recorded in the row (a
#     missing or stale one is a finding). apk packages carry no sha256 by design: the apk
#     database checksum (the Z: and C: entries) is a SHA-1 based value, not a SHA-256, so it is
#     recorded as "apk database checksum" and never as a hash;
#   - the files under /opt/halow/artifacts in the image are hashed here and compared with the
#     provenance rows for artifacts (path and sha256) in both directions: an artifact in the
#     image without a row, a row without a file, and a stale checksum are findings; the image's
#     own MANIFEST.sha256 must list exactly those files with those checksums;
#   - Embedded libraries (rows named embedded:*) have no file of their own. What can be checked:
#     the set of embedded: rows must equal EXPECTED_EMBEDDED below, and for each library that has
#     a marker the carrier file in the image must contain a library-specific byte string (the
#     markers are listed in EMB_MARKERS). What cannot be verified from the image: the executables
#     are stripped and static, so the library versions (OpenSSL 3.5.9, glibc, libnl 3.11.0) are
#     not stated by any string in them; the version and licence facts of those rows come from
#     the build record only, and libnl has no marker at all (recorded as not verifiable);
#   - a non-apk component's tree checksum (tree-sha256) is the SHA-256 of the text made by running
#     sha256sum on the regular files under a stated path set, in byte-wise sorted path order
#     (lines of hash, two spaces, relative path, newline); symlinks and directories are not
#     covered. The path set of an s6 part is its /package/<category>/<name>-<version> directory;
#     for s6-overlay it also includes init, etc/s6-overlay and etc/fix-attrs.d; for bashio it is
#     usr/lib/bashio. The digest is computed from the image root with the paths relative to it.
#     A version that the image does not state (jemalloc, bashio) stays "inferred" from the base
#     image build file;
#   - every file that no apk package owns must belong to a known group (see unowned-files.txt);
#   - the image must set no LD_PRELOAD or MALLOC_CONF and have no /etc/ld.so.preload, and no
#     file outside /usr/local may name libjemalloc (jemalloc is present but must stay unused
#     until a row and a decision say otherwise).
# The files are always written. If any of these checks fails the script prints the findings
# and exits with status 2, so a stale provenance record cannot pass unnoticed.
#
# Usage:
#   tools/generate_sbom.sh [IMAGE [OUTDIR]]
#   tools/generate_sbom.sh --from-dir OUTDIR     (no docker: redo steps 4 to 6 from the
#                                                 intermediate files already in OUTDIR; the
#                                                 tests use this with small fixtures)
#   IMAGE defaults to morse-micro-halow-ap:local; OUTDIR defaults to ${TMPDIR:-/tmp}/halow-sbom-out
#   HALOW_PROVENANCE=path   read this provenance file instead of ../provenance.psv (tests)
# Needs: docker (able to run linux/arm64 images, e.g. through QEMU), python3, awk.
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADDON_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FROM_DIR=""
if [ "${1:-}" = "--from-dir" ]; then
    FROM_DIR="${2:?usage: generate_sbom.sh --from-dir OUTDIR}"
    IMAGE="from-dir"
    OUT="$FROM_DIR"
else
    IMAGE="${1:-morse-micro-halow-ap:local}"
    OUT="${2:-${TMPDIR:-/tmp}/halow-sbom-out}"
fi
PROV="${HALOW_PROVENANCE:-$ADDON_DIR/provenance.psv}"

NEED_TOOLS="python3 awk"
[ -n "$FROM_DIR" ] || NEED_TOOLS="docker $NEED_TOOLS"
for tool in $NEED_TOOLS; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: $tool not found on PATH" >&2; exit 1; }
done
[ -f "$PROV" ] || { echo "ERROR: $PROV not found" >&2; exit 1; }
if [ -n "$FROM_DIR" ]; then
    [ -d "$OUT" ] || { echo "ERROR: $OUT is not a directory" >&2; exit 1; }
else
    docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "ERROR: image $IMAGE not found (run BUILD_IMAGE=1 ./build.sh first)" >&2; exit 1; }
    mkdir -p "$OUT"
fi

echo "== SBOM for $IMAGE -> $OUT =="

# Everything below runs in one throwaway container with no network and a read-only root.
# The entrypoint is replaced so the add-on's own init does not start.
run_in_image() {
    docker run --rm --platform linux/arm64 --network none --read-only --entrypoint sh "$IMAGE" -c "$1"
}

if [ -z "$FROM_DIR" ]; then
# 1. image metadata
{
    echo "image reference:   $IMAGE"
    echo "image id:          $(docker image inspect "$IMAGE" --format '{{.Id}}')"
    echo "architecture:      $(docker image inspect "$IMAGE" --format '{{.Os}}/{{.Architecture}}')"
    echo "repo digests:      $(docker image inspect "$IMAGE" --format '{{json .RepoDigests}}')"
    echo "(a local build has no registry digest; the id above is the local content id)"
    echo "labels:"
    docker image inspect "$IMAGE" --format '{{range $k, $v := .Config.Labels}}  {{$k}}={{$v}}{{"\n"}}{{end}}' | sort
    echo "base image (from the build label): $(docker image inspect "$IMAGE" --format '{{index .Config.Labels "io.halow.build.base"}}')"
    echo "-- /etc/os-release --"
    run_in_image 'cat /etc/os-release'
    echo "-- /etc/apk/repositories --"
    run_in_image 'cat /etc/apk/repositories'
    echo "-- /etc/apk/world --"
    run_in_image 'cat /etc/apk/world'
    echo "-- /usr/share/licenses in the image --"
    run_in_image 'find /usr/share/licenses -type f 2>/dev/null | sort; true'
    echo "-- image environment (Config.Env) --"
    docker image inspect "$IMAGE" --format '{{range .Config.Env}}{{println .}}{{end}}' | sed 's/^/ENV: /'
    echo "-- /etc/ld.so.preload --"
    run_in_image 'if [ -e /etc/ld.so.preload ]; then echo "present"; cat /etc/ld.so.preload; else echo "absent"; fi'
} > "$OUT/image-info.txt"

# 2. apk database
run_in_image 'cat /lib/apk/db/installed' > "$OUT/apk-installed.db"
awk -v RS= -F'\n' '
    function flush() {
        if (name == "") return
        lic = (nlic > 0) ? lics : "none"
        printf "%s | %s | %s | %s | %s | %s | %s | %s | %s\n", name, ver, arch, (origin == "" ? "not recorded" : origin), (licence == "" ? "not recorded" : licence), (url == "" ? "not recorded" : url), (commit == "" ? "not recorded" : commit), (csum == "" ? "not recorded" : csum), lic
    }
    BEGIN { print "# name | version | arch | origin | licence (as recorded by apk, unverified) | homepage | aports commit | apk db checksum | licence files in image" }
    {
        name = ver = arch = origin = licence = url = commit = csum = ""; lics = ""; nlic = 0; dir = ""
        for (i = 1; i <= NF; i++) {
            k = substr($i, 1, 2); v = substr($i, 3)
            if (k == "P:") name = v
            else if (k == "V:") ver = v
            else if (k == "A:") arch = v
            else if (k == "o:") origin = v
            else if (k == "L:") licence = v
            else if (k == "U:") url = v
            else if (k == "c:") commit = v
            else if (k == "C:") csum = v
            else if (k == "F:") dir = v
            else if (k == "R:") {
                p = dir "/" v
                if (p ~ /(^|\/)(usr\/share\/licenses|usr\/share\/doc)\// || v ~ /^(COPYING|LICENSE|LICENCE|NOTICE|COPYRIGHT)/) { lics = lics (nlic ? ", " : "") "/" p; nlic++ }
            }
        }
        flush()
    }' "$OUT/apk-installed.db" | { read -r header; echo "$header"; sort; } > "$OUT/apk-packages.psv"

# 3. components installed outside apk by the base image, each with the checksum measured in the
#    image (sha256= for one file, tree-sha256= for a tree; see the header for the tree definition)
{
    echo "# component | version | where | licence recorded in the image | notes"
    run_in_image 'cd /; for d in /package/*/; do for p in "$d"*-[0-9]*; do [ -d "$p" ] || continue; rel="${p#/}"; extra=""; case "$rel" in */s6-overlay-[0-9]*) extra="init etc/s6-overlay etc/fix-attrs.d" ;; esac; n=$(find $rel $extra -type f | wc -l); dg=$(find $rel $extra -type f | LC_ALL=C sort | xargs sha256sum | sha256sum | cut -d" " -f1); echo "$p|$n|$dg|$rel $extra"; done; done' | while IFS="|" read -r p n dg paths; do
        base="${p##*/}"
        echo "${base%-[0-9]*} | ${base##*-} | $p | not recorded | installed by the base image's s6-overlay; version taken from the directory name; tree-sha256=$dg over $n regular file(s) under: ${paths% }"
    done
    tv="$(run_in_image 'tempio -h 2>&1 | sed -n "1s/^Version: //p"' || true)"
    ts="$(run_in_image 'sha256sum /usr/bin/tempio 2>/dev/null | cut -d" " -f1' || true)"
    echo "tempio | ${tv:-not recorded} | /usr/bin/tempio | not recorded | Go program installed by the base image; version from its own help output; sha256=$ts"
    bd="$(run_in_image 'cd /; n=$(find usr/lib/bashio -type f | wc -l); dg=$(find usr/lib/bashio -type f | LC_ALL=C sort | xargs sha256sum | sha256sum | cut -d" " -f1); echo "$n|$dg"' || true)"
    echo "bashio | not recorded | /usr/lib/bashio and /usr/bin/bashio | not recorded | shell library installed by the base image; the image states no version; tree-sha256=${bd#*|} over ${bd%%|*} regular file(s) under: usr/lib/bashio"
    # jemalloc: compiled from source by the base image build and copied to /usr/local; not an apk package.
    # The library prints a placeholder version (it was built from a git checkout without tags).
    jl="$(run_in_image 'for f in /usr/local/lib/libjemalloc.so.*; do [ -f "$f" ] && [ ! -L "$f" ] && echo "$f"; done' || true)"
    for f in $jl; do
        js="$(run_in_image "sha256sum '$f' | cut -d' ' -f1" || true)"
        jv="$(run_in_image 'jemalloc-config --version 2>/dev/null' || true)"
        case "$jv" in ''|0.0.0-0-g000000missing*) jv="not stated in the image" ;; esac
        echo "jemalloc | $jv | $f (with jemalloc-config, jemalloc.sh and jeprof in /usr/local/bin) | not recorded | built from source by the base image, not an apk package; sha256=$js"
    done
    # the one configuration file the base image copies in from its own rootfs directory
    ps="$(run_in_image 'sha256sum /etc/pip.conf 2>/dev/null | cut -d" " -f1' || true)"
    if [ -n "$ps" ]; then
        echo "base-image-config | not applicable | /etc/pip.conf | not recorded | pip settings file added by the base image; sha256=$ps"
    fi
    # the CA bundle: a data file that the apk database lists under ca-certificates-bundle
    cs="$(run_in_image 'f=/etc/ssl/certs/ca-certificates.crt; [ -f "$f" ] && echo "$(sha256sum "$f" | cut -d" " -f1)|$(wc -c < "$f" | tr -d " ")"' || true)"
    if [ -n "$cs" ]; then
        echo "ca-bundle | not applicable | /etc/ssl/certs/ca-certificates.crt | not recorded | CA certificate bundle (data file); sha256=${cs%%|*}; ${cs#*|} bytes"
    fi
} > "$OUT/non-apk-components.psv"

# 3a. the artifacts under /opt/halow/artifacts, hashed here (MANIFEST.sha256 excluded), the image's
#     own MANIFEST.sha256, and the byte-string markers of the embedded libraries in their carriers
run_in_image 'cd /opt/halow/artifacts && find . -type f ! -name MANIFEST.sha256 | LC_ALL=C sort | xargs sha256sum' > "$OUT/image-artifacts.sha256"
run_in_image 'cat /opt/halow/artifacts/MANIFEST.sha256' > "$OUT/image-artifacts-manifest.sha256"
# EMB_MARKERS: key|carrier file under /opt/halow/artifacts|byte string. A marker is evidence that
# the library is in the carrier; it states no version (the executables are stripped and static).
# libnl has no marker (no string in the stripped executable names it); see the header.
EMB_MARKERS=(
    "embedded:openssl|hostapd_s1g|/usr/local/ssl"
    "embedded:openssl|hostapd_s1g|OPENSSL_"
    "embedded:glibc|hostapd_s1g|GLIBC"
    "embedded:glibc|hostapd_cli_s1g|GLIBC"
    "embedded:libgcc|hostapd_s1g|GCC: (Buildroot -gd2b75e05) 13.4.0"
    "embedded:libgcc|hostapd_cli_s1g|GCC: (Buildroot -gd2b75e05) 13.4.0"
    "embedded:mmrc|morse.ko|MMRC_BW_1MHZ"
)
emb_script="cd /opt/halow/artifacts; "
for m in "${EMB_MARKERS[@]}"; do
    IFS='|' read -r mk mf mb <<< "$m"
    emb_script+="printf '%s | %s | %s | %s\\n' '$mk' '$mf' '$mb' \"\$(grep -a -c -F -- '$mb' '$mf')\"; "
done
{
    echo "# embedded library | carrier file | marker string | lines of the carrier file in the image that contain the marker"
    run_in_image "$emb_script"
} > "$OUT/embedded-evidence.txt"

# 3b. every regular file and symlink in the image, and the files that name libjemalloc
run_in_image 'find / -xdev \( -type f -o -type l \) -exec sh -c '"'"'for f; do if [ -L "$f" ]; then echo "l $f $(readlink "$f")"; else echo "f $f"; fi; done'"'"' sh {} +' | LC_ALL=C sort -k2 > "$OUT/image-files.txt"
# (python3 in the image reads every file once; a busybox grep over the whole image takes minutes under emulation)
docker run --rm -i --platform linux/arm64 --network none --read-only --entrypoint python3 "$IMAGE" - <<'PYSCAN' | LC_ALL=C sort > "$OUT/jemalloc-references.txt"
import os
needle = b"libjemalloc"
skip = ("/proc", "/sys", "/dev")
for dp, dn, fn in os.walk("/"):
    dn[:] = [d for d in dn if os.path.join(dp, d) not in skip]
    for f in fn:
        p = os.path.join(dp, f)
        if os.path.islink(p):
            continue
        try:
            with open(p, "rb") as fh:
                while True:
                    b = fh.read(1 << 22)
                    if not b:
                        break
                    if needle in b:
                        print(p)
                        break
        except OSError:
            pass
PYSCAN
fi

# 4. bundled artifacts, from the provenance record in this directory
{
    echo "# path | sha256 | component | licence (as recorded) | licence_check | redistribution"
    grep -v -E '^[[:space:]]*(#|$)' "$PROV" | awk -F'|' '
        { for (i = 1; i <= NF; i++) gsub(/^[ \t]+|[ \t]+$/, "", $i) }
        $1 !~ /^image-/ { printf "%s | %s | %s | %s | %s | %s\n", $1, $2, $3, $6, $8, $9 }'
} > "$OUT/artifacts.psv"

# 5. summary
{
    echo "Licence summary for $IMAGE (licence strings are as recorded by apk metadata; unverified)"
    echo
    echo "Installed Alpine packages: $(grep -c -v '^#' "$OUT/apk-packages.psv")"
    echo
    echo "-- distinct licence strings and number of packages --"
    grep -v '^#' "$OUT/apk-packages.psv" | awk -F' [|] ' '{ c[$5]++ } END { for (l in c) printf "%4d  %s\n", c[l], l }' | sort -k2
    echo
    echo "-- packages with no licence file in the image --"
    grep -v '^#' "$OUT/apk-packages.psv" | awk -F' [|] ' '$9 == "none" { printf "%s %s (%s)\n", $1, $2, $5 }'
    echo
    echo "-- packages whose licence is not recorded by apk --"
    grep -v '^#' "$OUT/apk-packages.psv" | awk -F' [|] ' '$5 == "not recorded" { printf "%s %s\n", $1, $2 }'
    echo
    echo "-- components outside apk (no licence recorded in the image; licence fields are in provenance.psv) --"
    # a version the image does not state is taken from the provenance row and marked as inferred
    grep -v '^#' "$PROV" | grep '^image-component:' | awk -F'|' '
        { k = $1; gsub(/^[ \t]+|[ \t]+$/, "", k); sub(/^image-component:/, "", k); v = $5; gsub(/^[ \t]+|[ \t]+$/, "", v)
          if (match(v, /^version [^ ,;()]+/)) pv[k] = substr(v, 9, RLENGTH - 8) }
        END { for (k in pv) print k "\t" pv[k] }' > "$OUT/.provver.tmp"
    grep -v '^#' "$OUT/non-apk-components.psv" | awk -F' [|] ' -v vf="$OUT/.provver.tmp" '
        BEGIN { while ((getline l < vf) > 0) { split(l, a, "\t"); pv[a[1]] = a[2] } }
        { v = $2
          if ((v == "not recorded" || v == "not stated in the image") && ($1 in pv)) v = pv[$1] " (inferred from the provenance row; not stated by the image)"
          else if (v == "not applicable") v = "(no version)"
          printf "%s %s\n", $1, v }'
    rm -f "$OUT/.provver.tmp"
    echo
    echo "-- bundled artifacts whose licence check is not 'confirmed' --"
    grep -v '^#' "$OUT/artifacts.psv" | awk -F' [|] ' '$5 != "confirmed" { printf "%s (%s)\n", $1, $5 }'
} > "$OUT/licences-summary.txt"

# 6. CycloneDX 1.5 JSON (no timestamp, so two runs on the same image give the same bytes),
#    and the cross-check against provenance.psv
RC=0
python3 -I - "$OUT" "$IMAGE" "$PROV" <<'PY' || RC=$?
import json, os, re, sys

out, image, prov_path = sys.argv[1], sys.argv[2], sys.argv[3]
HEX64 = re.compile(r"^[0-9a-f]{64}$")
PLACEHOLDER_VERSIONS = ("not recorded", "not stated in the image", "not applicable")
# non-apk components for which the image must yield a measured checksum (a missing one is a finding)
EXPECT_MEASURED = ("tempio", "bashio", "jemalloc", "ca-bundle")


def rows(name, required=True):
    path = os.path.join(out, name)
    if not os.path.exists(path):
        if required:
            raise SystemExit("ERROR: %s is missing in %s" % (name, out))
        return
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if line and not line.startswith("#"):
                yield [f.strip() for f in line.split(" | ")]


def prop(name, value):
    return {"name": "halow:" + name, "value": value}


# provenance.psv, keyed by path (ten fields per row)
prov = {}
with open(prov_path, encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        f = [x.strip() for x in line.split("|")]
        if len(f) != 10:
            raise SystemExit("ERROR: provenance row with %d fields: %s" % (len(f), f[0]))
        prov[f[0]] = f

covered = set()          # provenance keys that have an SBOM component
problems = []            # findings that make the run fail
notes = []               # findings that do not


def prov_props(key):
    f = prov[key]
    return [prop("provenance-row", key), prop("source", f[3]), prop("source-ref", f[4]),
            prop("licence-text", f[6]), prop("licence-check", f[7]), prop("redistribution", f[8])]


info = open(os.path.join(out, "image-info.txt"), encoding="utf-8").read() if os.path.exists(os.path.join(out, "image-info.txt")) else ""
image_id = next((l.split(None, 2)[2] for l in info.splitlines() if l.startswith("image id:")), "not recorded")
base = next((l.split(": ", 1)[1] for l in info.splitlines() if l.startswith("base image (from the build label)")), "not recorded")
distro = next((l.split("=", 1)[1].strip('"') for l in info.splitlines() if l.startswith("VERSION_ID=")), "not recorded")

components = []

# --- Alpine packages (from the apk database) ---
apk_names = []
for name, ver, arch, origin, lic, url, commit, csum, licfiles in rows("apk-packages.psv"):
    apk_names.append(name)
    c = {
        "type": "library",
        "bom-ref": "apk:%s@%s" % (name, ver),
        "name": name,
        "version": ver,
        "purl": "pkg:apk/alpine/%s@%s?arch=%s&distro=alpine-%s" % (name, ver, arch, distro),
        "licenses": [{"license": {"name": lic}}] if lic != "not recorded" else [],
        "properties": [
            prop("licence-check", prov.get("image-package:" + name, [None] * 10)[7] or "unverified (apk metadata only)"),
            prop("origin", origin), prop("aports-commit", commit), prop("apk-db-checksum", csum),
            prop("licence-files-in-image", licfiles),
            prop("redistribution", prov.get("image-package:" + name, [None] * 10)[8] or "not recorded"),
        ],
    }
    if url != "not recorded":
        c["externalReferences"] = [{"type": "website", "url": url}]
    key = "image-package:" + name
    if key not in prov:
        problems.append("image package %s %s has no row %s in provenance.psv" % (name, ver, key))
    else:
        covered.add(key)
        comp = prov[key][2]
        if (name + " " + ver + " ") not in comp + " ":
            problems.append("image package %s: installed version %s is not the one in provenance row %s (%s)" % (name, ver, key, comp))
        c["properties"].append(prop("provenance-row", key))
    components.append(c)

# --- non-apk components found in the image ---
# A licence name must be short; a long statement in the provenance row goes into a property.
# These names do not classify the licence: they only point to the row.
SHORT_LICENCE_NAMES = {
    "image-component:jemalloc": "see COPYING text (no licence named by the text)",
    "image-component:base-image-config": "Apache-2.0 at repository level (see halow:licence-description)",
}


def licence_name(key, text):
    if len(text) <= 80:
        return text
    return SHORT_LICENCE_NAMES.get(key, "see halow:licence-description (long statement in the provenance row)")


for name, ver, where, lic, note in rows("non-apk-components.psv"):
    key = "image-component:" + name
    shown_ver = ver
    props = [prop("where", where), prop("notes", note)]
    c = {"type": "data" if name == "ca-bundle" else "application", "name": name}
    if key not in prov:
        problems.append("non-apk component %s (%s) has no row %s in provenance.psv" % (name, where, key))
    else:
        covered.add(key)
        f = prov[key]
        m = re.match(r"version (\S+)", f[4])
        if ver in PLACEHOLDER_VERSIONS and m:
            shown_ver = m.group(1).rstrip(",;")
            props.append(prop("version-source", "inferred from the provenance row (the image does not state it)"))
        elif m and ver not in PLACEHOLDER_VERSIONS and m.group(1).rstrip(",;") != ver:
            problems.append("non-apk component %s: version %s found in the image, provenance row says %s" % (name, ver, m.group(1)))
        elif ver in PLACEHOLDER_VERSIONS:
            shown_ver = ver
        if shown_ver not in PLACEHOLDER_VERSIONS:
            c["version"] = shown_ver
        props = props + prov_props(key)
        if not f[5].startswith(("not recorded", "none")):
            c["licenses"] = [{"license": {"name": licence_name(key, f[5])}}]
            props.append(prop("licence-description", f[5]))
        # the checksum measured in the image must be in the row, and must be the same
        sm = re.search(r"(?<![\w-])sha256=([0-9a-f]{64})", note)
        tm = re.search(r"tree-sha256=([0-9a-f]{64})", note)
        measured = (sm or tm).group(1) if (sm or tm) else None
        if measured is not None:
            kind = "file" if sm else "tree"
            if not HEX64.match(f[1]):
                problems.append("non-apk component %s: the image has %s SHA-256 %s but provenance row %s records none" % (name, kind, measured, key))
            elif measured != f[1]:
                problems.append("non-apk component %s: the %s in the image has SHA-256 %s, provenance row says %s" % (name, kind, measured, f[1]))
        elif name in EXPECT_MEASURED or where.startswith("/package/"):
            problems.append("non-apk component %s: no checksum could be measured in the image" % name)
        if HEX64.match(f[1]):
            if tm and not sm:
                props.append(prop("tree-sha256", f[1]))
                props.append(prop("tree-sha256-definition", "SHA-256 of the sorted sha256sum list of the regular files under the stated paths (see the notes property and the generator header)"))
            else:
                c["hashes"] = [{"alg": "SHA-256", "content": f[1]}]
        if f[3].startswith("https://"):
            c["externalReferences"] = [{"type": "vcs", "url": f[3].split(" ", 1)[0]}]
    c["bom-ref"] = "base:" + re.sub(r"[^A-Za-z0-9._:+~-]", "-", name + ("@" + c["version"] if "version" in c else ""))
    c["properties"] = props
    components.append(c)

# --- the base image itself and the add-on's own files (no file to find; the rows are the record) ---
for key, ctype in (("image-component:base-image", "container"), ("image-component:addon-own-code", "application")):
    if key not in prov:
        problems.append("provenance.psv has no row %s" % key)
        continue
    covered.add(key)
    f = prov[key]
    c = {"type": ctype, "bom-ref": key, "name": f[2], "properties": prov_props(key)}
    if HEX64.match(f[1]):
        c["hashes"] = [{"alg": "SHA-256", "content": f[1]}]
    components.append(c)

# --- bundled artifacts and embedded libraries (from provenance.psv through artifacts.psv) ---
# The files themselves are measured in the image (image-artifacts.sha256) and compared with the rows.
def read_sums(name):
    path = os.path.join(out, name)
    if not os.path.exists(path):
        return None
    d = {}
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line.strip():
                continue
            m = re.match(r"^([0-9a-f]{64})  (\S.*)$", line)
            if m:
                d[m.group(2)] = m.group(1)
            else:
                problems.append("%s: unreadable line: %s" % (name, line[:80]))
    return d


img_art = read_sums("image-artifacts.sha256")
img_man = read_sums("image-artifacts-manifest.sha256")
prov_art = {k: f for k, f in prov.items() if k.startswith("./")}
if img_art is None:
    problems.append("image-artifacts.sha256 is missing: the bundled artifacts were not measured in the image, so the artifact rows cannot be cross-checked")
else:
    for p in sorted(img_art):
        if p not in prov_art:
            problems.append("artifact %s is in the image (SHA-256 %s) but has no row in provenance.psv" % (p, img_art[p]))
        elif prov_art[p][1] != img_art[p]:
            problems.append("artifact %s: the file in the image has SHA-256 %s, provenance row says %s (stale)" % (p, img_art[p], prov_art[p][1]))
    for p in sorted(prov_art):
        if p not in img_art:
            problems.append("provenance row %s has no file under /opt/halow/artifacts in the image" % p)
if img_man is None:
    problems.append("image-artifacts-manifest.sha256 is missing: the image's own MANIFEST.sha256 was not read")
elif img_art is not None:
    for p in sorted(set(img_man) | set(img_art)):
        if p not in img_art:
            problems.append("the image's MANIFEST.sha256 lists %s, which is not under /opt/halow/artifacts in the image" % p)
        elif p not in img_man:
            problems.append("%s is under /opt/halow/artifacts in the image but not in the image's MANIFEST.sha256" % p)
        elif img_man[p] != img_art[p]:
            problems.append("the image's MANIFEST.sha256 says %s for %s, the file hashes to %s" % (img_man[p], p, img_art[p]))

for path, sha, comp, lic, chk, red in rows("artifacts.psv"):
    if img_art is not None and path in img_art:
        sha = img_art[path]          # the measured value (equal to the row's unless a finding was raised above)
    c = {
        "type": "file" if path.startswith("./") else "library",
        "bom-ref": "artifact:" + path, "name": comp,
        "licenses": [{"license": {"name": lic}}],
        "properties": [prop("path", path), prop("licence-check", chk), prop("redistribution", red)],
    }
    if path in prov:
        covered.add(path)
        c["properties"].extend(p for p in prov_props(path) if p["name"] not in ("halow:licence-check", "halow:redistribution"))
    else:
        problems.append("artifact %s has no row in provenance.psv" % path)
    if HEX64.match(sha):
        c["hashes"] = [{"alg": "SHA-256", "content": sha}]
    components.append(c)
for path in sorted(img_art or {}):
    if path not in prov_art:      # in the image, no row: still listed, and already a finding above
        components.append({"type": "file", "bom-ref": "artifact:" + path, "name": path,
                           "hashes": [{"alg": "SHA-256", "content": img_art[path]}],
                           "properties": [prop("path", path), prop("provenance-row", "none")]})

# --- embedded libraries: no file of their own; check the set of rows and the evidence in the carriers ---
EXPECTED_EMBEDDED = ("embedded:glibc", "embedded:libgcc", "embedded:libnl", "embedded:mmrc", "embedded:openssl")
# no string in the stripped static executables names libnl, so nothing can be checked in the image
EMB_UNVERIFIABLE = ("embedded:libnl",)
for k in EXPECTED_EMBEDDED:
    if k not in prov:
        problems.append("expected embedded library row %s is missing from provenance.psv" % k)
for k in sorted(prov):
    if k.startswith("embedded:") and k not in EXPECTED_EMBEDDED:
        problems.append("provenance row %s is an embedded library that the generator does not expect (add it to EXPECTED_EMBEDDED with a marker, or declare it unverifiable)" % k)
if not os.path.exists(os.path.join(out, "embedded-evidence.txt")):
    problems.append("embedded-evidence.txt is missing: the embedded libraries could not be checked against the carriers in the image")
else:
    ev = [r for r in rows("embedded-evidence.txt") if len(r) == 4]
    for k in EXPECTED_EMBEDDED:
        if k in EMB_UNVERIFIABLE:
            notes.append("%s cannot be verified from the image (no marker string; the executables are stripped and static); the row is the build record only" % k)
            continue
        mine = [r for r in ev if r[0] == k]
        if not mine:
            problems.append("no marker evidence was collected for %s" % k)
        for r in mine:
            if not r[3].isdigit() or int(r[3]) < 1:
                problems.append("%s: the marker '%s' was not found in %s in the image" % (k, r[2], r[1]))
    notes.append("embedded library versions (OpenSSL, glibc, libnl, libgcc) are not stated by the stripped executables; they come from the build record only")

# --- every provenance row must have an SBOM component ---
for key in prov:
    if key not in covered:
        problems.append("provenance row %s has no component in the SBOM (the image or the generator does not produce it)" % key)

# --- files that no apk package owns must belong to a known group ---
def owned_set():
    owned, d = set(), ""
    path = os.path.join(out, "apk-installed.db")
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if line.startswith("F:"):
                d = line[2:]
            elif line.startswith("R:"):
                owned.add((d + "/" + line[2:]).lstrip("/"))
            elif line == "":
                d = ""
    return owned


def classify(kind, path, target):
    if kind == "l" and target.endswith("busybox"):
        return "busybox applet symlink (created by busybox --install; busybox is an apk package)"
    if path.startswith("package/"):
        return "s6-overlay tree (/package, installed by the base image)"
    if path.startswith("command/") or (kind == "l" and "/command/" in target):
        return "s6-overlay command symlinks (installed by the base image)"
    if path in ("init",) or path.startswith(("etc/s6-overlay/", "etc/fix-attrs.d/")):
        return "s6-overlay entry point and bundles (installed by the base image)"
    if path.startswith("usr/lib/bashio/") or path == "usr/bin/bashio":
        return "bashio (installed by the base image)"
    if path == "usr/bin/tempio":
        return "tempio (installed by the base image)"
    if path.startswith("usr/local/") and ("jemalloc" in path or path == "usr/local/bin/jeprof"):
        return "jemalloc (compiled by the base image build)"
    if path == "etc/pip.conf":
        return "base image configuration file"
    if path.startswith("etc/ssl/certs/") and kind == "l":
        return "certificate hash links (made by the ca-certificates package trigger)"
    if path.startswith(("opt/halow/", "usr/lib/halow/", "usr/share/halow/", "usr/share/licenses/morse_micro_halow_ap/", "etc/services.d/", "etc/cont-init.d/")):
        return "the add-on's own files"
    if path.startswith(("etc/apk/", "lib/apk/")) or path in ("etc/passwd-", "etc/group-", "etc/shadow-"):
        return "package manager state and account-file backups"
    if path in (".dockerenv", "etc/resolv.conf", "etc/hosts", "etc/hostname", "etc/mtab"):
        return "container runtime files"
    return "UNCLASSIFIED"


audit_lines = []
owned = owned_set()
files_path = os.path.join(out, "image-files.txt")
if owned is not None and os.path.exists(files_path):
    groups = {}
    with open(files_path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.rstrip("\n")
            parts = line.split(" ", 2)
            kind, path = parts[0], parts[1].lstrip("/")
            target = parts[2] if len(parts) > 2 else ""
            if path in owned or path.startswith(("proc/", "sys/", "dev/")):
                continue
            g = classify(kind, path, target)
            groups.setdefault(g, []).append(path)
    audit_lines.append("# files in the image that no apk package owns, by group (count, then paths)")
    for g in sorted(groups):
        audit_lines.append("== %s: %d" % (g, len(groups[g])))
        for p in groups[g]:
            audit_lines.append("   " + p)
    if "UNCLASSIFIED" in groups:
        problems.append("%d file(s) in the image belong to no apk package and to no known group (see unowned-files.txt): %s" % (
            len(groups["UNCLASSIFIED"]), ", ".join(groups["UNCLASSIFIED"][:8])))
    with open(os.path.join(out, "unowned-files.txt"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(audit_lines) + "\n")
else:
    notes.append("file ownership audit not run (image-files.txt or apk-installed.db missing)")

# --- jemalloc must stay unused ---
if info:
    for l in info.splitlines():
        if l.startswith("ENV: ") and re.match(r"ENV: (LD_PRELOAD|MALLOC_CONF)=", l):
            problems.append("the image environment sets %s" % l[5:].split("=")[0])
    if "-- /etc/ld.so.preload --\npresent" in info:
        problems.append("the image has /etc/ld.so.preload")
refs = os.path.join(out, "jemalloc-references.txt")
if os.path.exists(refs):
    for line in open(refs, encoding="utf-8", errors="replace"):
        line = line.strip()
        if line and not line.startswith("/usr/local/") and not line.startswith("/lib/apk/") and not line.startswith("/etc/") and not line.startswith("/usr/share/licenses/morse_micro_halow_ap/"):
            problems.append("%s contains the name libjemalloc (jemalloc is expected to be referenced only from /usr/local)" % line)

bom = {
    "bomFormat": "CycloneDX", "specVersion": "1.5", "version": 1,
    "metadata": {
        "component": {"type": "container", "name": image, "bom-ref": "image",
                      "properties": [prop("image-id", image_id), prop("base-image", base)]},
        "properties": [prop("status", "inventory generated from the exact image and provenance.psv; licence-check and redistribution values are per component; not legal advice")],
    },
    "components": components,
}
with open(os.path.join(out, "sbom.cdx.json"), "w", encoding="utf-8") as fh:
    json.dump(bom, fh, indent=2, sort_keys=True)
    fh.write("\n")
print("components:", len(components))

with open(os.path.join(out, "provenance-coverage.txt"), "w", encoding="utf-8") as fh:
    fh.write("provenance rows: %d; SBOM components: %d; rows with an SBOM component: %d\n" % (len(prov), len(components), len(covered)))
    fh.write("result: %s\n" % ("FAILED, %d finding(s)" % len(problems) if problems else "complete (every row and every component cross-checked)"))
    for p in problems:
        fh.write("FINDING: %s\n" % p)
    for n in notes:
        fh.write("NOTE: %s\n" % n)
for p in problems:
    print("FINDING: " + p, file=sys.stderr)
for n in notes:
    print("NOTE: " + n, file=sys.stderr)
sys.exit(2 if problems else 0)
PY

echo "apk packages:      $(grep -c -v '^#' "$OUT/apk-packages.psv")"
echo "non-apk components: $(grep -c -v '^#' "$OUT/non-apk-components.psv")"
echo "written to:        $OUT"
echo "cross-check:       $(sed -n 2p "$OUT/provenance-coverage.txt" 2>/dev/null)"
if [ "$RC" -ne 0 ]; then
    echo "== Done, but the provenance cross-check found problems (exit status $RC); see $OUT/provenance-coverage.txt =="
    exit "$RC"
fi
echo "== Done =="
