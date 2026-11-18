#!/usr/bin/env bash
# Repository-boundary scan. This directory is meant to be publishable software: nothing in
# it may point back at private project records, governance identifiers, internal
# milestone/phase vocabulary, a person's machine, or carry a secret.
#
# The patterns are assembled from fragments at run time so that this file does not itself
# contain the strings it forbids, and it scans itself like every other file.
#
# Scope: every file in the add-on directory except the staged binary artifacts
# (artifacts/, which are not text and are not committed).
# Labs tree variant: the checks for private-project vocabulary run only in the private working tree.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
. tests/test_helpers.sh

echo "== test_public_boundary =="


# name | extended regex
#
# A name starting with "(i)" is matched case-insensitively.
PATTERNS=(
  "(i) home directory path|/ho""me/[a-z]"
  "email address|[A-Za-z0-9._-]+@[A-Za-z0-9-]+\\.[A-Za-z]{2,}"
  "(i) Windows or user path|/Us""ers/|[A-Za-z]:\\\\"
  "private key block|BEGIN [A-Z ]*PRIVATE KEY"
  "ssh key material|ssh-(rsa|ed25519) [A-Za-z0-9+/]{20,}"
  "pasted credential|(passphrase|password|secret|token)[\"']?[[:space:]]*[:=][[:space:]]*[\"'][^\"'\$]{4,}[\"']"
  "(i) build-machine path|/mnt/""c/|wsl\\.local""host|\\\\\\\\w""sl\\b"
  "(i) internal tracker or wiki|atlass""ian\\.net|conflu""ence|\\bji""ra\\b"
  "(t) rendered access-point secret|(wpa_passphrase|sae_password|wpa_psk)=[^\$\"'{%[:space:]<]{4,}"
  "(t) Supervisor token value|(SUPERVISOR|HASSIO)_TOKEN[\"']?[[:space:]]*[:=][[:space:]]*[\"']?[A-Za-z0-9._-]{16,}"
  "bearer token value|Bearer [A-Za-z0-9._-]{20,}"
  "YAML option default for a secret|^[[:space:]]+(wifi_)?(passphrase|password|psk|secret|token):[[:space:]]*[^[:space:]\"']"
)
# A name starting with "(t)" is not applied under tests/ (test fixtures deliberately hold
# obviously fake values of that shape, to prove they are redacted).

mapfile -t FILES < <(find . -type f ! -path './artifacts/*' ! -name '*.actual' | sort)
assert_success "there are files to scan" test "${#FILES[@]}" -gt 5

_hit_file="$(mktemp)"
_text_file="$(mktemp)"
scan_file() {
    local f="$1" entry name rx hits="" flag="-E" in_tests=0
    case "$f" in ./tests/*) in_tests=1 ;; esac
    # Exempt: a schema line declaring the password TYPE (`: "password"` or
    # `: "password(12,63)"`), and one kernel configuration symbol.
    sed -E "/: \"password(\\([0-9,]*\\))?\"$/d; /^CONFIG_CHECK""POINT_RESTORE=/d" "$f" > "$_text_file" 2>/dev/null
    for entry in "${PATTERNS[@]}"; do
        name="${entry%%|*}"; rx="${entry#*|}"; flag="-E"
        # The verbatim third-party license texts carry their authors' published contact addresses;
        # they are copied unchanged and are exempt from the e-mail pattern only.
        case "$name:$f" in "email address:./third-party-notices/"*|"email address:./LICENSES/"*|"email address:./legal-stage/"*) continue ;; esac
        case "$name" in "(t) "*) [ "$in_tests" -eq 1 ] && continue; name="${name#(t) }" ;; esac
        case "$name" in "(i) "*) flag="-i -E"; name="${name#(i) }" ;; esac
        if grep -n $flag -- "$rx" "$_text_file" >"$_hit_file" 2>/dev/null; then
            hits="${hits}    [$name] $(head -n1 "$_hit_file" | cut -c1-110)\n"
        fi
    done
    printf '%b' "$hits"
}

dirty=0
for f in "${FILES[@]}"; do
    # The two presentation images are binary PNG artwork: a text pattern scan of compressed
    # image bytes is meaningless. test_presentation_assets.sh checks that they carry no metadata.
    case "$f" in ./icon.png|./logo.png) continue ;; esac
    out="$(scan_file "$f")"
    if [ -n "$out" ]; then
        dirty=1
        echo "  FINDINGS in $f:"; printf '%s\n' "$out"
    fi
done
assert_eq "0" "$dirty" "no file contains a private-record reference, governance identifier, personal path or secret pattern"

echo "-- the scanner catches each kind of leak (samples assembled at run time, outside the tree) --"
_sample="$(mktemp)"
_q='"'
while IFS= read -r sample; do
    [ -n "$sample" ] || continue
    sample="${sample//\"\"/}"    # join the fragments that keep this file itself clean
    printf '%s\n' "$sample" > "$_sample"
    assert_success "detected: a $(cut -c1-12 <<< "$sample")… sample" test -n "$(scan_file "$_sample")"
done <<EOF
  wifi_pass""phrase: hunter2hunter2
  wifi_pass""phrase: ${_q}correct-horse-battery${_q}
sae_pass""word=correct-horse-battery
wpa_pass""phrase=correct-horse-battery
SUPERVISOR_TO""KEN=abcdefghijklmnop1234
Authorization: Bear""er abcdefghijklmnopqrstuvwxyz012345
cd /mnt""/c/work
open https://example.atlass""ian.net/browse/X-1
EOF
for allowed in '  wifi_pass''phrase: "password(12,63)"' '  wifi_pass''phrase: "password"' 'IPv4 and IPv6' 'tcp/1883'; do
    printf '%s\n' "$allowed" > "$_sample"
    assert_eq "" "$(scan_file "$_sample")" "not a leak: '$allowed'"
done
rm -f "$_sample" "$_hit_file" "$_text_file"

echo "-- the README states the development status plainly --"
assert_success "README.md names version 1.0.0 as the first release" grep -qF 'Version `1.0.0`, the first release.' README.md
assert_failure "README.md carries no release-candidate or pre-release wording" grep -q -i -E "release candidate|pre-release|experimental" README.md
assert_failure "README.md carries no network-interruption warning (the old requirement is retired)" grep -q -i "network interruption" README.md
assert_failure "README.md carries no placeholder, internal-path, signing or hardware-owner wording" grep -q -i -E "PLACEHOLDER|local[- ]apps|OPERATIONS\.md|unsigned|taint|firmware search path|the Green" README.md
assert_failure "README.md contains no em dash" bash -c 'grep -q "$(printf "\342\200\224")" README.md'
assert_success "README.md links exactly the approved URLs (two Morse Micro pages, the security-disclosure form and the GitHub Issues page) and no other" bash -c 'urls="$(grep -o -E "https?://[^ )>\"]+" README.md | sed "s/[.,;]*$//" | sort -u)"; [ "$urls" = "$(printf "%s\n%s\n%s\n%s\n" "https://www.morsemicro.com/" "https://www.morsemicro.com/products/development-resources/wi-fi-halow-usb-network-adapters" "https://www.morsemicro.com/policy/security-disclosure" "https://github.com/MorseMicroLabs/home-assistant-halow/issues" | sort -u)" ]'
assert_success "README.md makes no production-readiness or certification claim" bash -c '! grep -q -i -E "production[- ]ready|certified|compliant" README.md'
assert_success "the add-on manifest is version 1.0.0 with stage stable and carries no release-candidate or Experimental wording" \
    bash -c 'grep -qx "version: \"1.0.0\"" config.yaml && grep -qx "stage: stable" config.yaml && ! grep -q -i -E "release candidate|experimental" config.yaml'
assert_failure "the manifest header (first six lines), the manifest description and the Dockerfile carry no development-build or not-production-ready wording" \
    bash -c '{ sed -n "1,6p" config.yaml; sed -n "/^description:/,/^stage:/p" config.yaml; cat Dockerfile; } | grep -q -i -E "development build|not production-ready"'

echo "-- no staged binary is tracked as source --"
assert_success ".gitignore keeps the staged artifacts out of the repository" grep -q '^artifacts/$' .gitignore

echo "test_public_boundary: $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed"
exit $([ "$HALOW_TEST_FAILURES" -eq 0 ] && echo 0 || echo 1)
