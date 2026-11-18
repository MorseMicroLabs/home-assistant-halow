#!/usr/bin/env bash
# Verifies a directory of corresponding-source release assets against the committed manifest
# (source-assets/ASSETS.psv). Local files only: no network. It proves that the assets are completely
# prepared; it does not prove that they are published (tools/final_publication_check.sh does that).
#
# Checks, each printed as OK or FAIL:
#   - every manifest row has a file in DIR with the recorded size and sha256;
#   - archive assets list cleanly (tar -t) and contain the recorded member;
#   - DIR holds exactly the manifest assets plus SHA256SUMS and nothing else;
#   - SHA256SUMS equals the checksum list generated from the manifest;
#   - SOURCE-INDEX.md and kernel-prep.sh in DIR are byte-identical to the copies in the repository;
#   - the release-asset address of every asset is deterministic (url_base + name).
#
# Usage: tools/verify_source_assets.sh [--addon DIR_OF_halow-addon] ASSETS_DIR
# Exit status: 0 when every check passes, 1 otherwise, 2 on a usage error.
set -o nounset -o pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADDON="$_here/.."
while [ "$#" -gt 0 ]; do
    case "$1" in
        --addon) ADDON="${2:-}"; shift 2 ;;
        -h|--help) echo "usage: verify_source_assets.sh [--addon DIR] ASSETS_DIR" >&2; exit 2 ;;
        *) break ;;
    esac
done
DIR="${1:-}"
if [ -z "$DIR" ] || [ ! -d "$DIR" ]; then
    echo "usage: verify_source_assets.sh [--addon DIR] ASSETS_DIR" >&2
    exit 2
fi
ADDON="$(cd "$ADDON" && pwd)"
DIR="$(cd "$DIR" && pwd)"
MAN="$ADDON/source-assets/ASSETS.psv"
[ -f "$MAN" ] || { echo "ERROR: $MAN is missing" >&2; exit 1; }

export LC_ALL=C
LISTING="$(mktemp)"
trap 'rm -f "$LISTING"' EXIT
FAILS=0
ok() { echo "OK   $*"; }
bad() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }

base="$(tr -d '\r' < "$MAN" | sed -n 's/^# url_base: *//p' | head -n1)"
[[ "$base" =~ ^https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/releases/download/v[0-9][A-Za-z0-9._-]*/$ ]] \
    && ok "url_base is a deterministic release-download address: $base" || bad "url_base is not a release-download address: '$base'"

names=()
sums=""
while IFS='|' read -r name size sha covers lic member kind note; do
    name="$(echo "$name" | xargs)"; size="$(echo "$size" | xargs)"; sha="$(echo "$sha" | xargs)"
    member="$(echo "$member" | xargs)"; kind="$(echo "$kind" | xargs)"
    [ -n "$name" ] || continue
    names+=("$name")
    sums="${sums}${sha}  ${name}"$'\n'
    f="$DIR/$name"
    if [ ! -f "$f" ]; then bad "$name: file is missing"; continue; fi
    if [ "$(stat -c %s "$f")" = "$size" ]; then ok "$name: size $size"; else bad "$name: size is $(stat -c %s "$f"), recorded $size"; fi
    if [ "$(sha256sum "$f" | awk '{print $1}')" = "$sha" ]; then ok "$name: sha256 matches"; else bad "$name: sha256 differs from the manifest"; fi
    case "$kind" in
        tar.gz|tar.xz|tar)
            if tar -tf "$f" > "$LISTING" 2>/dev/null; then
                if [ "$member" = "-" ] || grep -qxF -- "$member" "$LISTING"; then ok "$name: lists cleanly and holds $member"; else bad "$name: member $member not found"; fi
            else bad "$name: tar cannot list it"; fi ;;
        text) : ;;
        *) bad "$name: unknown kind '$kind'" ;;
    esac
done < <(tr -d '\r' < "$MAN" | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$')

[ "${#names[@]}" -gt 0 ] && ok "the manifest lists ${#names[@]} assets" || bad "the manifest lists no assets"

# the directory holds exactly the manifest assets plus SHA256SUMS
expected="$( { printf '%s\n' "${names[@]}"; echo SHA256SUMS; } | sort)"
actual="$(cd "$DIR" && find . -mindepth 1 -maxdepth 1 | sed 's#^\./##' | sort)"
if [ "$expected" = "$actual" ]; then ok "the directory holds exactly the manifest assets and SHA256SUMS"; else bad "the directory differs from the manifest: $(diff <(echo "$expected") <(echo "$actual") | grep '^[<>]' | head -n5 | paste -sd' ')"; fi

# SHA256SUMS equals the list generated from the manifest (sorted by name, two spaces)
gen="$(printf '%s' "$sums" | sort -k2)"
if [ -f "$DIR/SHA256SUMS" ] && [ "$(tr -d '\r' < "$DIR/SHA256SUMS")" = "$gen" ]; then ok "SHA256SUMS equals the manifest checksum list"; else bad "SHA256SUMS is missing or differs from the manifest checksum list"; fi
if [ -f "$DIR/SHA256SUMS" ] && (cd "$DIR" && sha256sum -c SHA256SUMS >/dev/null 2>&1); then ok "sha256sum -c SHA256SUMS passes"; else bad "sha256sum -c SHA256SUMS fails"; fi

# the two files that exist both in the repository and as assets are identical
for pair in "SOURCE-INDEX.md:$ADDON/source-assets/SOURCE-INDEX.md" "kernel-prep.sh:$ADDON/source-offer/kernel-prep.sh"; do
    n="${pair%%:*}"; r="${pair#*:}"
    if [ -f "$DIR/$n" ] && [ -f "$r" ] && cmp -s "$DIR/$n" "$r"; then ok "$n is byte-identical to the repository copy"; else bad "$n differs from (or is missing next to) the repository copy"; fi
done

for n in "${names[@]}"; do
    [[ "$n" =~ ^[A-Za-z0-9._-]+$ ]] || bad "$n is not a URL-safe name"
done

if [ "$FAILS" -eq 0 ]; then echo "verify_source_assets: all checks passed (${#names[@]} assets)"; exit 0; fi
echo "verify_source_assets: $FAILS check(s) FAILED"
exit 1
