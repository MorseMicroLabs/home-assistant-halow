#!/usr/bin/env bash
# Final-publication check for the corresponding-source release assets. It uses the network and no
# credentials: it asks, from outside, whether every asset of source-assets/ASSETS.psv (and SHA256SUMS)
# is reachable at its release-download address with the recorded content. It exits 0 only when every
# asset is reachable and, in the default full mode, its SHA-256 matches. Until then it BLOCKs, which is the
# correct state before the public release step.
#
# It does not change any file. When a full run passes it prints the two lines to record in
# source-assets/PUBLICATION-STATUS (`status: published` and the SHA-256 of the manifest it checked);
# final_release_gate.sh gate 14 reads them and checks that the manifest has not changed since.
#
# Usage: tools/final_publication_check.sh [--size-only] [--addon DIR]
#   default      downloads every asset and compares its SHA-256 (large: several hundred MB)
#   --size-only  checks only reachability and size; it never authorizes recording `published`
# The address base is the url_base of the manifest. HALOW_SOURCE_URL_BASE replaces it only together with
# HALOW_PUBLICATION_CHECK_TEST=1 (used by the tests, with a file:// base); the base used is always printed.
# Anonymous access only: curl runs with -q (no .curlrc) and no credentials.
# Exit status: 0 all reachable, 1 at least one asset is not, 2 usage error.
set -o nounset -o pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADDON="$_here/.."
FULL=1
while [ "$#" -gt 0 ]; do
    case "$1" in
        --full) FULL=1; shift ;;
        --size-only) FULL=0; shift ;;
        --addon) ADDON="${2:-}"; shift 2 ;;
        *) echo "usage: final_publication_check.sh [--full] [--addon DIR]" >&2; exit 2 ;;
    esac
done
ADDON="$(cd "$ADDON" && pwd)"
MAN="$ADDON/source-assets/ASSETS.psv"
[ -f "$MAN" ] || { echo "ERROR: $MAN is missing" >&2; exit 2; }
base="$(tr -d '\r' < "$MAN" | sed -n 's/^# url_base: *//p' | head -n1)"
if [ -n "${HALOW_SOURCE_URL_BASE:-}" ]; then
    if [ "${HALOW_PUBLICATION_CHECK_TEST:-0}" = "1" ]; then base="$HALOW_SOURCE_URL_BASE"
    else echo "ERROR: HALOW_SOURCE_URL_BASE is honored only with HALOW_PUBLICATION_CHECK_TEST=1 (the check must use the manifest address)" >&2; exit 2; fi
fi
[ -n "$base" ] || { echo "ERROR: no url_base" >&2; exit 2; }
echo "address base: $base"

BAD=0; N=0
while IFS='|' read -r name size sha rest; do
    name="$(echo "$name" | xargs)"; size="$(echo "$size" | xargs)"; sha="$(echo "$sha" | xargs)"
    [ -n "$name" ] || continue
    N=$((N + 1))
    url="${base}${name}"
    case "$url" in
        file://*)
            f="${url#file://}"
            if [ -f "$f" ]; then got_code=200; got_size="$(stat -c %s "$f")"; else got_code=404; got_size=0; fi ;;
        *)
            hdr="$(curl -q -sIL --max-time 60 -A 'halow-publication-check' "$url" 2>/dev/null | tr -d '\r')"
            got_code="$(printf '%s\n' "$hdr" | awk '/^HTTP/ {c=$2} END {print c+0}')"
            got_size="$(printf '%s\n' "$hdr" | awk 'tolower($1)=="content-length:" {s=$2} END {print s+0}')" ;;
    esac
    if [ "$got_code" != "200" ]; then
        echo "BLOCK $name: not reachable (HTTP $got_code) at $url"; BAD=$((BAD + 1)); continue
    fi
    if [ "$got_size" != "$size" ]; then
        echo "BLOCK $name: reachable but its size is $got_size, recorded $size"; BAD=$((BAD + 1)); continue
    fi
    if [ "$FULL" -eq 1 ]; then
        got_sha="$(curl -q -sL --max-time 1800 "$url" | sha256sum | awk '{print $1}')"
        [ "$url" != "${url#file://}" ] && got_sha="$(sha256sum "${url#file://}" | awk '{print $1}')"
        if [ "$got_sha" != "$sha" ]; then echo "BLOCK $name: sha256 of the published file differs"; BAD=$((BAD + 1)); continue; fi
    fi
    echo "OK    $name: reachable, $size bytes$( [ "$FULL" -eq 1 ] && echo ', sha256 matches')"
done < <(tr -d '\r' < "$MAN" | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$')

# SHA256SUMS is an asset too: its size follows from the manifest (one line per row: 64 hex digits, two
# spaces, the name, a newline).
sums_size=0
while IFS='|' read -r name rest; do
    name="$(echo "$name" | xargs)"; [ -n "$name" ] || continue
    sums_size=$((sums_size + 64 + 2 + ${#name} + 1))
done < <(tr -d '\r' < "$MAN" | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$')
url="${base}SHA256SUMS"
case "$url" in
    file://*) f="${url#file://}"; if [ -f "$f" ]; then got_code=200; got_size="$(stat -c %s "$f")"; else got_code=404; got_size=0; fi ;;
    *) hdr="$(curl -q -sIL --max-time 60 -A 'halow-publication-check' "$url" 2>/dev/null | tr -d '\r')"
       got_code="$(printf '%s\n' "$hdr" | awk '/^HTTP/ {c=$2} END {print c+0}')"
       got_size="$(printf '%s\n' "$hdr" | awk 'tolower($1)=="content-length:" {s=$2} END {print s+0}')" ;;
esac
N=$((N + 1))
if [ "$got_code" != "200" ]; then echo "BLOCK SHA256SUMS: not reachable (HTTP $got_code) at $url"; BAD=$((BAD + 1))
elif [ "$got_size" != "$sums_size" ]; then echo "BLOCK SHA256SUMS: reachable but its size is $got_size, expected $sums_size"; BAD=$((BAD + 1))
else
    sums_ok=1
    if [ "$FULL" -eq 1 ]; then
        want_sums="$(tr -d '\r' < "$MAN" | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$' | awk -F'|' '{n=$1; h=$3; gsub(/^[ \t]+|[ \t]+$/, "", n); gsub(/^[ \t]+|[ \t]+$/, "", h); print h "  " n}' | LC_ALL=C sort -k2)"
        case "$url" in
            file://*) got_sums="$(cat "${url#file://}")" ;;
            *) got_sums="$(curl -q -sL --max-time 300 "$url")" ;;
        esac
        [ "$got_sums" = "$want_sums" ] || sums_ok=0
    fi
    if [ "$sums_ok" -eq 1 ]; then echo "OK    SHA256SUMS: reachable, $sums_size bytes$( [ "$FULL" -eq 1 ] && echo ', content matches the manifest')"
    else echo "BLOCK SHA256SUMS: the published file differs from the checksum list generated from the manifest"; BAD=$((BAD + 1)); fi
fi

if [ "$BAD" -eq 0 ] && [ "$N" -gt 0 ]; then
    if [ "$FULL" -eq 1 ]; then
        echo "final_publication_check: all $N assets are reachable and their SHA-256 values match"
        echo "Record these two lines in halow-addon/source-assets/PUBLICATION-STATUS:"
        echo "status: published"
        echo "manifest-sha256: $(sha256sum "$MAN" | awk '{print $1}')"
    else
        echo "final_publication_check: all $N assets are reachable with the recorded size (size-only: this does NOT authorize recording published; run without --size-only)"
    fi
    exit 0
fi
echo "final_publication_check: BLOCKED ($BAD of $N assets are not reachable as recorded)"
exit 1
