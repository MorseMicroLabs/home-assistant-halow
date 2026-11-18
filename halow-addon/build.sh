#!/usr/bin/env bash
# Artifact staging + (optional) image build for the Morse Micro Wi-Fi HaLow Access Point for Home Assistant
# (version from config.yaml). Off-device only.
#
# This script does not build the driver or hostapd. It takes them from a
# separately built, checksum-verified artifact bundle (the directory
# named by ARTIFACT_BUNDLE_DIR, required: it has no default; produced by that
# directory's own build script) and stages only the files this add-on
# needs. A reproducible, in-tree build pipeline is later work.
#
# What this script does, in order:
#   1. Verifies <bundle>/output/ against the bundle's own tracked MANIFEST.sha256 —
#      fails loudly, changes nothing, if the bundle is missing or does not match (never
#      trust an unverified upstream build).
#   2. Copies the specific subset of files this add-on actually needs into ./artifacts/.
#   3. Computes a fresh manifest for ./artifacts/ and compares it against this
#      directory's own tracked MANIFEST.sha256 (explicit-accept-to-update design).
#   4. Prints the pinned build inputs read from the Dockerfile (the base image digest and
#      every exact package pin) and the artifact manifest's own checksum; refuses to go on
#      if the Dockerfile has an unpinned base or package.
#   5. Optionally builds the Docker image, if BUILD_IMAGE=1 and docker is usable, recording
#      those same inputs as image labels so the image carries what it was built from.
#
# Usage:
#   ./build.sh                       # stage + verify artifacts only
#   BUILD_IMAGE=1 ./build.sh         # also attempt `docker build`
#   NO_CACHE=1 BUILD_IMAGE=1 ./build.sh   # the same, without reusing any cached layer
#   UPDATE_EXPECTED_MANIFEST=1 ./build.sh   # accept a new golden manifest after review
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

UPSTREAM_DIR="${ARTIFACT_BUNDLE_DIR:-}"
if [ -z "$UPSTREAM_DIR" ]; then
    echo "ERROR: set ARTIFACT_BUNDLE_DIR to the directory holding the separately built artifact bundle" >&2
    echo "(an output/ directory and a MANIFEST.sha256)." >&2
    exit 1
fi
UPSTREAM_OUTPUT="${UPSTREAM_DIR}/output"
UPSTREAM_MANIFEST="${UPSTREAM_DIR}/MANIFEST.sha256"

echo "== Morse Micro Wi-Fi HaLow Access Point for Home Assistant: staging artifacts from the verified artifact bundle =="

if [ ! -d "$UPSTREAM_OUTPUT" ]; then
    echo "ERROR: $UPSTREAM_OUTPUT does not exist." >&2
    echo "Run ${UPSTREAM_DIR}/build.sh first to produce the artifact bundle." >&2
    exit 1
fi
if [ ! -f "$UPSTREAM_MANIFEST" ]; then
    echo "ERROR: $UPSTREAM_MANIFEST not found." >&2
    exit 1
fi

echo "-- Verifying the artifact bundle against its own tracked manifest --"
(
    cd "$UPSTREAM_OUTPUT"
    sha256sum -c "../MANIFEST.sha256" --ignore-missing
)
echo "Artifact bundle verified OK."

rm -rf artifacts
mkdir -p artifacts/bcf

# The exact subset this add-on needs — nothing else. Each copy is immediately
# re-verified against the upstream manifest's own checksum before this script trusts it.
copy_verified() {
    local rel="$1" dest="$2"
    local expected
    expected="$(awk -v p="./${rel}" '$2 == p { print $1; exit }' "$UPSTREAM_MANIFEST")"
    if [ -z "$expected" ]; then
        echo "ERROR: no manifest entry for $rel in $UPSTREAM_MANIFEST" >&2
        exit 1
    fi
    cp -- "${UPSTREAM_OUTPUT}/${rel}" "$dest"
    local actual
    actual="$(sha256sum -- "$dest" | awk '{print $1}')"
    if [ "$actual" != "$expected" ]; then
        echo "ERROR: checksum mismatch copying $rel (expected $expected, got $actual)" >&2
        exit 1
    fi
}

copy_verified "morse.ko" "artifacts/morse.ko"
copy_verified "dot11ah.ko" "artifacts/dot11ah.ko"
copy_verified "mm8108b2-rl.bin" "artifacts/mm8108b2-rl.bin"
copy_verified "bcf/bcf_boardtype_0807.bin" "artifacts/bcf/bcf_boardtype_0807.bin"
copy_verified "hostapd_s1g" "artifacts/hostapd_s1g"
copy_verified "hostapd_cli_s1g" "artifacts/hostapd_cli_s1g"
copy_verified "hostapd_s1g.conf" "artifacts/hostapd_s1g.conf"

echo "All 7 files copied and individually re-verified."

echo "-- Generating this add-on's own manifest for ./artifacts/ --"
# Normalised to the "<sha>  <path>" (two-space) form explicitly, via awk, rather than
# trusting `sha256sum`'s own default output format: that default genuinely differs by
# platform for byte-identical input (confirmed directly — this exact command produced
# the "*"-prefixed binary-mode form under Windows Git Bash and the plain two-space form
# under WSL2 while developing this script), which would otherwise make this manifest
# comparison spuriously fail depending only on which shell happened to run the build.
(
    cd artifacts
    find . -type f | sort | xargs sha256sum | awk '{ $1=$1; sha=$1; $1=""; path=$0; sub(/^[ \t]+\*?/, "", path); print sha "  " path }'
) > MANIFEST.sha256.actual

if [ "${UPDATE_EXPECTED_MANIFEST:-0}" = "1" ]; then
    cp MANIFEST.sha256.actual MANIFEST.sha256
    echo "MANIFEST.sha256 updated and accepted (UPDATE_EXPECTED_MANIFEST=1)."
elif [ -f MANIFEST.sha256 ]; then
    if diff -u MANIFEST.sha256 MANIFEST.sha256.actual; then
        echo "artifacts/ matches the tracked MANIFEST.sha256 exactly."
    else
        echo "ERROR: artifacts/ does not match the tracked MANIFEST.sha256 (diff above)." >&2
        echo "If this change is expected and reviewed, re-run with UPDATE_EXPECTED_MANIFEST=1." >&2
        rm -f MANIFEST.sha256.actual
        exit 1
    fi
else
    echo "No tracked MANIFEST.sha256 yet — run with UPDATE_EXPECTED_MANIFEST=1 to create it." >&2
    rm -f MANIFEST.sha256.actual
    exit 1
fi
rm -f MANIFEST.sha256.actual

echo "-- Gathering the license, notice and source-record files into legal-stage/ --"
rm -rf legal-stage
mkdir legal-stage
for f in LICENSE NOTICE THIRD-PARTY-NOTICES.md SOURCE-OFFER.md PROVENANCE.md provenance.psv corresponding_source.psv source_disposition.psv; do
    [ -s "$f" ] || { echo "ERROR: $f is missing or empty" >&2; exit 1; }
    cp "$f" legal-stage/
done
for d in LICENSES third-party-notices source-offer; do
    [ -d "$d" ] || { echo "ERROR: $d/ is missing" >&2; exit 1; }
    cp -R "$d" legal-stage/
done
# The source-asset manifest and index travel with the image; PUBLICATION-STATUS does not (it
# changes at publication and must not change the image).
mkdir legal-stage/source-assets
for f in ASSETS.psv SOURCE-INDEX.md; do
    [ -s "source-assets/$f" ] || { echo "ERROR: source-assets/$f is missing or empty" >&2; exit 1; }
    cp "source-assets/$f" legal-stage/source-assets/
done
stray="$(find legal-stage \( -name 'PUBLICATION-STATUS' -o -name '*.actual' -o -name '*.log' -o -name '.*' \) -mindepth 1 | head -n3)"
[ -z "$stray" ] || { echo "ERROR: legal-stage/ holds files that must not ship: $stray" >&2; exit 1; }
echo "legal-stage/ holds $(find legal-stage -type f | wc -l | tr -d ' ') files."

echo "-- Pinned build inputs (read from the Dockerfile) --"
BASE_REF="$(awk '$1 == "FROM" { print $2; exit }' Dockerfile)"
case "$BASE_REF" in
    *@sha256:[0-9a-f]*) : ;;
    *) echo "ERROR: the Dockerfile's base image is not pinned by digest: $BASE_REF" >&2; exit 1 ;;
esac
# Every package argument of the apk add instruction (up to the first &&), joined across
# continuation lines.
APK_PINS="$(awk '
    /apk add/ { inrun = 1; done = 0 }
    inrun {
        line = $0; cont = (line ~ /\\[[:space:]]*$/); sub(/\\[[:space:]]*$/, "", line)
        n = split(line, w, /[[:space:]]+/)
        for (i = 1; i <= n && !done; i++) {
            if (w[i] == "&&") { done = 1; break }
            if (w[i] != "" && w[i] !~ /^(RUN|apk|add|--no-cache)$/) printf "%s ", w[i]
        }
        if (!cont) inrun = 0
    }' Dockerfile)"
APK_PINS="${APK_PINS% }"
if [ -z "$APK_PINS" ]; then
    echo "ERROR: no apk add instruction found in the Dockerfile" >&2; exit 1
fi
for pkg in $APK_PINS; do
    case "$pkg" in
        *=[0-9]*-r[0-9]*) : ;;
        *) echo "ERROR: package '$pkg' in the Dockerfile is not pinned to an exact version" >&2; exit 1 ;;
    esac
done
MANIFEST_SHA="$(sha256sum MANIFEST.sha256 | awk '{print $1}')"
echo "base image:        $BASE_REF"
echo "packages:          $APK_PINS"
echo "artifact manifest: sha256 $MANIFEST_SHA"
# The release version is read from config.yaml (the one place it is set) and must equal
# the Dockerfile's version labels; the image is also tagged with it, so a build of a new
# version keeps the earlier versions' tags. Rebuilding the SAME version re-points that
# version's tag (and morse-micro-halow-ap:local) at the new image; record the image id each time.
VERSION="$(awk -F'"' '/^version:/ { print $2; exit }' config.yaml)"
case "$VERSION" in
    [0-9]*.[0-9]*.[0-9]*) : ;;
    *) echo "ERROR: could not read a version from config.yaml: '$VERSION'" >&2; exit 1 ;;
esac
for _label in io.hass.version org.opencontainers.image.version; do
    if ! grep -qF "${_label}=\"${VERSION}\"" Dockerfile; then
        echo "ERROR: the Dockerfile label ${_label} does not equal the config.yaml version ${VERSION}" >&2
        exit 1
    fi
done
echo "version:           $VERSION"

if [ "${BUILD_IMAGE:-0}" = "1" ]; then
    echo "-- Building the Docker image (BUILD_IMAGE=1) --"
    if ! command -v docker >/dev/null 2>&1; then
        echo "ERROR: docker not found on PATH." >&2
        exit 1
    fi
    # Plain `docker build --platform` (BuildKit), not `docker buildx build`: this is the
    # simplest invocation that produces a genuine linux/arm64 image on a Docker
    # installation with a working daemon and BuildKit/QEMU cross-platform support (a
    # single-platform `docker build --platform` target does not require the `buildx`
    # plugin specifically). Use `docker buildx build` instead if your own environment
    # already relies on it, or if you want multi-arch output in one invocation.
    NO_CACHE_FLAG=""; [ "${NO_CACHE:-0}" = "1" ] && NO_CACHE_FLAG="--no-cache"
    DOCKER_BUILDKIT=1 docker build --platform linux/arm64 \
        --label "io.halow.build.base=${BASE_REF}" \
        --label "io.halow.build.packages=${APK_PINS}" \
        --label "io.halow.build.artifact-manifest-sha256=${MANIFEST_SHA}" \
        --label "io.halow.build.version=${VERSION}" \
        --label "org.opencontainers.image.created=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        ${NO_CACHE_FLAG} \
        -t morse-micro-halow-ap:local \
        -t "morse-micro-halow-ap:${VERSION}" .
    echo "Image built: morse-micro-halow-ap:local and morse-micro-halow-ap:${VERSION}"
    echo "image id:    $(docker image inspect --format '{{.Id}}' "morse-micro-halow-ap:${VERSION}")"
else
    echo "Skipping image build (set BUILD_IMAGE=1 to build it)."
fi

echo "== Done =="
