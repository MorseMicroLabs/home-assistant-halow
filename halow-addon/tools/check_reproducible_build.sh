#!/usr/bin/env bash
# Builds the add-on image twice from the same inputs, with BuildKit's reproducible-timestamp
# options, and compares the results layer by layer. Not part of the default test suite (it
# needs Docker with BuildKit and QEMU, network access to the base image registry and the
# Alpine repository, and several minutes).
#
#   SOURCE_DATE_EPOCH  timestamp written into the image and its files (default: 0)
#
# Exit 0: the two images are bit-for-bit identical (same manifest digest).
# Exit 1: they differ; the differing layers are listed with the build step that made them.
# Exit 2: the builds themselves could not be run.
set -euo pipefail
ADDON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ADDON_DIR"
EPOCH="${SOURCE_DATE_EPOCH:-0}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

command -v docker >/dev/null 2>&1 || { echo "docker is not available" >&2; exit 2; }
[ -d artifacts ] || { echo "artifacts/ is not staged; run build.sh first" >&2; exit 2; }

BASE_REF="$(awk '$1 == "FROM" { print $2; exit }' Dockerfile)"
PINS="$(awk '/apk add/ {r = 1} r { line = $0; c = (line ~ /\\[[:space:]]*$/); sub(/\\[[:space:]]*$/, "", line); n = split(line, w, /[[:space:]]+/); for (i = 1; i <= n; i++) if (w[i] ~ /=/) printf "%s ", w[i]; if (!c) r = 0 }' Dockerfile)"
PINS="${PINS% }"
MANIFEST_SHA="$(sha256sum MANIFEST.sha256 | awk '{print $1}')"

build_once() { # build_once <n>
    mkdir -p "$WORK/$1"
    if ! DOCKER_BUILDKIT=1 docker buildx build --platform linux/arm64 --no-cache \
        --provenance=false --sbom=false \
        --build-arg "SOURCE_DATE_EPOCH=${EPOCH}" \
        --label "io.halow.build.base=${BASE_REF}" \
        --label "io.halow.build.packages=${PINS}" \
        --label "io.halow.build.artifact-manifest-sha256=${MANIFEST_SHA}" \
        --output "type=oci,dest=$WORK/$1.tar,rewrite-timestamp=true" \
        . > "$WORK/$1.log" 2>&1; then
        tail -n 30 "$WORK/$1.log" >&2
        echo "build $1 failed" >&2
        exit 2
    fi
    tar -xf "$WORK/$1.tar" -C "$WORK/$1"
}

echo "== building twice (SOURCE_DATE_EPOCH=$EPOCH, no cache) =="
build_once a
build_once b

# The image manifest the OCI index points at, and its layers in order.
manifest_of() { python3 -c '
import json, sys
d = sys.argv[1]
idx = json.load(open(d + "/index.json"))
m = idx["manifests"][0]["digest"]
if idx["manifests"][0].get("mediaType", "").endswith("index.v1+json") or idx["manifests"][0].get("mediaType", "").endswith("manifest.list.v2+json"):
    sub = json.load(open(d + "/blobs/sha256/" + m.split(":")[1]))
    m = sub["manifests"][0]["digest"]
man = json.load(open(d + "/blobs/sha256/" + m.split(":")[1]))
print("manifest " + m)
print("config " + man["config"]["digest"])
for i, l in enumerate(man["layers"]):
    print("layer%02d %s" % (i, l["digest"]))
' "$1"; }
manifest_of "$WORK/a" > "$WORK/a.txt"
manifest_of "$WORK/b" > "$WORK/b.txt"
echo "first:  $(awk '$1 == "manifest" {print $2}' "$WORK/a.txt")"
echo "second: $(awk '$1 == "manifest" {print $2}' "$WORK/b.txt")"
if diff -q "$WORK/a.txt" "$WORK/b.txt" >/dev/null; then
    echo "RESULT: reproducible — both builds produced the same image, bit for bit."
    exit 0
fi
echo "RESULT: NOT bit-for-bit reproducible. Differing entries (layer 0.. are the base image's, then one per build step):"
diff "$WORK/a.txt" "$WORK/b.txt" | sed 's/^/  /' || true
# Name the files that differ in each differing layer.
while read -r key da; do
    db="$(awk -v k="$key" '$1 == k {print $2}' "$WORK/b.txt")"
    [ "$da" = "$db" ] && continue
    case "$key" in layer*) ;; *) continue ;; esac
    [ -n "$db" ] || { echo "  -- $key: only in the first build --"; continue; }
    echo "  -- $key: entries whose content or metadata differ --"
    mkdir -p "$WORK/la" "$WORK/lb"
    tar --numeric-owner -tvf "$WORK/a/blobs/sha256/${da#sha256:}" | sort -k6 > "$WORK/la.list"
    tar --numeric-owner -tvf "$WORK/b/blobs/sha256/${db#sha256:}" | sort -k6 > "$WORK/lb.list"
    diff "$WORK/la.list" "$WORK/lb.list" > "$WORK/meta.diff" || true
    sed 's/^/     meta /' "$WORK/meta.diff" > "$WORK/meta.out"
    tar -xf "$WORK/a/blobs/sha256/${da#sha256:}" -C "$WORK/la" 2>/dev/null || true
    tar -xf "$WORK/b/blobs/sha256/${db#sha256:}" -C "$WORK/lb" 2>/dev/null || true
    diff -rq --no-dereference "$WORK/la" "$WORK/lb" > "$WORK/content.diff" 2>&1 || true
    sed 's/^/     content /' "$WORK/content.diff" > "$WORK/content.out"
    awk 'NR <= 20' "$WORK/meta.out" "$WORK/content.out"
    rm -rf "$WORK/la" "$WORK/lb"
done < "$WORK/a.txt"
exit 1
