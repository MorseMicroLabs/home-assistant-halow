#!/usr/bin/env bash
# Tests the license treatment of the repository (a record of a decision, not a legal conclusion):
#   - LICENSE is the verbatim Apache License 2.0 text and LICENSES/ holds the verbatim Apache-2.0 and
#     GPL-2.0 texts (SHA-256 of the texts as distributed by Debian's common-licenses), at the
#     repository root and mirrored in the app folder;
#   - NOTICE (root and app folder, identical) names the product, the copyright line and the license
#     boundary: Apache-2.0 application code; GPL-2.0-only kernel modules, unchanged and separate;
#     firmware and board data under the Morse Micro Binary Distribution License Agreement; every
#     other third-party component under its own license, not relicensed;
#   - THIRD-PARTY-NOTICES.md equals what tools/generate_third_party_notices.py produces from
#     provenance.psv, so no license string or verification status was edited by hand, and no
#     "unverified" row became "confirmed";
#   - both READMEs state the treatment and link LICENSE, NOTICE and THIRD-PARTY-NOTICES.md without
#     kernel, driver-signing or firmware-path wording;
#   - REUSE.toml parses, maps the kernel modules to GPL-2.0-only, maps every file under rootfs/ (the
#     files that enter the image) and the other original files to Apache-2.0, and maps nothing in
#     rootfs/ to another license;
#   - no license document claims to relicense a third-party component;
#   - the license files are not git-ignored and are not copied into the image in this round.
# Needs bash, sha256sum, grep, awk and python3 (3.11 or later, for tomllib).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
. tests/test_helpers.sh

ROOT=".."
APACHE_SHA="cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30"
GPL2_SHA="edaef632cbb643e4e7a221717a6c441a4c1a7c918e6e4d56debc3d8739b233f6"
sha() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
EMDASH="$(printf '\xe2\x80\x94')"

echo "== test_license_treatment =="

echo "-- the license texts are verbatim --"
for d in "$ROOT" "."; do
    assert_eq "$APACHE_SHA" "$(sha "$d/LICENSE")" "$d/LICENSE is the Apache License 2.0 text (SHA-256)"
    assert_eq "$APACHE_SHA" "$(sha "$d/LICENSES/Apache-2.0.txt")" "$d/LICENSES/Apache-2.0.txt is the Apache License 2.0 text (SHA-256)"
    assert_eq "$GPL2_SHA" "$(sha "$d/LICENSES/GPL-2.0-only.txt")" "$d/LICENSES/GPL-2.0-only.txt is the GNU GPL version 2 text (SHA-256)"
    assert_success "$d/LICENSE starts with the Apache License heading" bash -c 'sed -n "1,4p" "$0" | grep -q "Apache License" && sed -n "1,4p" "$0" | grep -q "Version 2.0, January 2004"' "$d/LICENSE"
    assert_success "$d/LICENSES/GPL-2.0-only.txt starts with the GPL heading" bash -c 'sed -n "1,4p" "$0" | grep -q "GNU GENERAL PUBLIC LICENSE" && sed -n "1,4p" "$0" | grep -q "Version 2, June 1991"' "$d/LICENSES/GPL-2.0-only.txt"
done
LIC_SET="Apache-2.0.txt BSD-3-Clause.txt GPL-2.0-only.txt ISC.txt LicenseRef-Morse-Micro-Binary-Distribution-License-Agreement.txt LicenseRef-Morse-Micro-Brand-Assets.txt LicenseRef-Third-Party-License-Texts.txt"
assert_eq "$LIC_SET" "$(ls "$ROOT/LICENSES" | paste -sd" ")" "the root LICENSES/ directory holds exactly the license texts of the ids REUSE.toml uses"
assert_eq "$LIC_SET" "$(ls LICENSES | paste -sd" ")" "the app folder LICENSES/ directory holds exactly the license texts of the ids REUSE.toml uses"
MM_SHA="6bdd9bbe92c57c4490a8a9456c5aefc39c0505f16a178683c15226d5189cabc7"
for d in "$ROOT" .; do
    assert_eq "$MM_SHA" "$(sha256sum "$d/LICENSES/LicenseRef-Morse-Micro-Binary-Distribution-License-Agreement.txt" | cut -d" " -f1)" "$d: the Morse Micro Binary Distribution License Agreement text is the exact upstream text"
    assert_success "$d: the brand notice carries the approved lines" bash -c 'grep -qxF "Copyright 2026 Morse Micro. All rights reserved." "$0" && grep -q "not licensed under the Apache" "$0" && grep -q "does not grant" "$0"' "$d/LICENSES/LicenseRef-Morse-Micro-Brand-Assets.txt"
done

echo "-- NOTICE --"
assert_success "NOTICE is identical at the root and in the app folder" cmp -s "$ROOT/NOTICE" NOTICE
assert_success "NOTICE names the product exactly" grep -qxF "Morse Micro Wi-Fi HaLow Access Point for Home Assistant" NOTICE
assert_success "NOTICE carries the copyright line" grep -qxF "Copyright 2026 Morse Micro" NOTICE
NOTICE_FLAT="$(tr '\n' ' ' < NOTICE | tr -s ' ')"
assert_success "NOTICE says the original application code is Apache License, Version 2.0" grep -qF "is licensed under the Apache License, Version 2.0" <<< "$NOTICE_FLAT"
assert_success "NOTICE says the Morse Micro driver modules are GPL-2.0-only, unchanged" grep -qF "(GPL-2.0-only), unchanged" <<< "$NOTICE_FLAT"
assert_success "NOTICE names morse.ko and dot11ah.ko" bash -c 'grep -q "morse.ko" NOTICE && grep -q "dot11ah.ko" NOTICE'
assert_success "NOTICE says the kernel modules are separate files and not part of the Apache-2.0 application code" grep -qF "They are not part of the Apache-2.0 application code" <<< "$NOTICE_FLAT"
assert_success "NOTICE says firmware and board data are under the Morse Micro Binary Distribution License Agreement" grep -qF "provided under the Morse Micro Binary Distribution License Agreement" <<< "$NOTICE_FLAT"
assert_success "NOTICE says third-party components keep their own licenses and are not relicensed" grep -qF "keep their own licenses. They are not relicensed here" <<< "$NOTICE_FLAT"
assert_success "NOTICE points to PROVENANCE.md, provenance.psv and THIRD-PARTY-NOTICES.md" bash -c 'grep -q "PROVENANCE.md" NOTICE && grep -q "provenance.psv" NOTICE && grep -q "THIRD-PARTY-NOTICES.md" NOTICE'
assert_success "NOTICE points to SOURCE-OFFER.md for the corresponding source" grep -qF "SOURCE-OFFER.md" NOTICE
assert_success "NOTICE says icon.png and logo.png are official Morse Micro brand assets, under brand usage terms, not Apache-2.0" grep -qF "icon.png and logo.png are official Morse Micro brand assets used as supplied, governed by Morse Micro trademark and brand usage terms, and are not licensed under the Apache License, Version 2.0" <<< "$NOTICE_FLAT"
assert_eq "0" "$(grep -c "$EMDASH" NOTICE)" "NOTICE has no em dash"
assert_failure "NOTICE draws no legal conclusion beyond the boundary (no 'compliant', 'cleared', 'permitted to redistribute')" grep -qiE "compliant|cleared|permitted to redistribute|legal advice" NOTICE

echo "-- THIRD-PARTY-NOTICES.md is generated from provenance.psv --"
gen="$(python3 -I tools/generate_third_party_notices.py provenance.psv)"
assert_success "THIRD-PARTY-NOTICES.md equals the generator output" bash -c '[ "$1" = "$(cat THIRD-PARTY-NOTICES.md)" ]' _ "$gen"
assert_success "the root THIRD-PARTY-NOTICES.md is the same file" cmp -s "$ROOT/THIRD-PARTY-NOTICES.md" THIRD-PARTY-NOTICES.md
rows="$(grep -v -E '^[[:space:]]*(#|$)' provenance.psv)"
nrows="$(printf '%s\n' "$rows" | wc -l | tr -d ' ')"
for st in confirmed apkbuild-confirmed from-bundle-record unverified; do
    want="$(printf '%s\n' "$rows" | awk -F'|' -v s="$st" '{x=$8; gsub(/^[ \t]+|[ \t]+$/, "", x); if (x == s) c++} END {print c + 0}')"
    got="$(grep -E "\| $st \|$" THIRD-PARTY-NOTICES.md | grep -vc '^| Category')"
    assert_eq "$want" "$got" "THIRD-PARTY-NOTICES.md lists exactly $want rows as $st (the number provenance.psv records; none upgraded)"
done
assert_success "THIRD-PARTY-NOTICES.md states the row count and the three status counts" grep -qF "The record has $nrows rows: $(printf '%s\n' "$rows" | awk -F'|' '{x=$8; gsub(/ /,"",x); if (x=="confirmed") c++} END {print c+0}') \`confirmed\`" THIRD-PARTY-NOTICES.md
assert_eq "110" "$nrows" "provenance.psv has 110 rows"
miss=0
while IFS= read -r r; do
    lic="$(awk -F'|' '{x=$6; gsub(/^[ \t]+|[ \t]+$/, "", x); print x}' <<< "$r")"
    esc="${lic//|/\\|}"
    grep -qF -- "| $esc |" THIRD-PARTY-NOTICES.md || { miss=1; echo "    license string not in the table: $lic"; }
done <<< "$rows"
assert_eq "0" "$miss" "every license string of provenance.psv appears in the table exactly as recorded"
assert_success "the table says the kernel modules are GPL-2.0-only as recorded" bash -c 'grep -qE "^\| \./morse\.ko \| GPL-2\.0-only \| confirmed \|$" THIRD-PARTY-NOTICES.md && grep -qE "^\| \./dot11ah\.ko \| GPL-2\.0-only \| confirmed \|$" THIRD-PARTY-NOTICES.md'
assert_eq "0" "$(grep -c "$EMDASH" THIRD-PARTY-NOTICES.md)" "THIRD-PARTY-NOTICES.md has no em dash"
own="$(printf '%s\n' "$rows" | awk -F'|' '{x=$1; gsub(/ /,"",x); if (x=="image-component:addon-own-code") print $6}')"
assert_success "the provenance row for the app's own files records Apache-2.0 (not 'not decided')" bash -c '[[ "$1" == *"Apache-2.0"* ]] && [[ "$1" != *"not been decided"* ]]' _ "$own"
assert_failure "provenance.psv no longer says the product license has not been decided" grep -q "product licence has not been decided" provenance.psv
assert_failure "corresponding_source.psv no longer says the add-on has no licence file" grep -q "this add-on has no licence file" corresponding_source.psv

echo "-- the READMEs --"
for r in "$ROOT/README.md" README.md; do
    flat="$(tr '\n' ' ' < "$r" | tr -s ' ')"
    assert_success "$r has a License section" grep -qx '## License' "$r"
    assert_success "$r says the application code is Apache License 2.0" grep -qF "Apache License 2.0" <<< "$flat"
    assert_success "$r says the Morse Micro driver modules are GPL-2.0-only and separate from the application code" grep -qE "GPL-2\.0-only.* separate from the application code|separate from the application code" <<< "$flat"
    assert_success "$r says the firmware and board data are under the Morse Micro Binary Distribution License Agreement" grep -qF "Morse Micro Binary Distribution License Agreement" <<< "$flat"
    assert_success "$r links LICENSE, NOTICE and THIRD-PARTY-NOTICES.md" bash -c 'grep -qF "](LICENSE)" "$0" && grep -qF "](NOTICE)" "$0" && grep -qF "](THIRD-PARTY-NOTICES.md)" "$0"' "$r"
    assert_failure "$r has no kernel-taint, unsigned-driver or firmware-path wording" grep -qiE "taint|unsigned|firmware path|firmware search" "$r"
    assert_eq "0" "$(grep -c "$EMDASH" "$r")" "$r has no em dash"
    assert_failure "$r makes no legal-compliance claim" grep -qiE "compliant|legally cleared|approved for publication" "$r"
done
assert_success "the changelog carries a License line for this release" grep -q "^- License: " CHANGELOG.md

echo "-- REUSE.toml --"
assert_file_exists "$ROOT/REUSE.toml" "REUSE.toml exists at the repository root"
cat > "${TMPDIR:-/tmp}/reuse_check.$$.py" <<'PYEOF'
import os, re, sys, tomllib

root = sys.argv[1]
with open(os.path.join(root, "REUSE.toml"), "rb") as fh:
    cfg = tomllib.load(fh)
assert cfg["version"] == 1, "REUSE.toml version"
ann = cfg["annotations"]


def rx(pattern):
    out, i = "", 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out += "(?:.*/)?"
            i += 3
        elif pattern.startswith("**", i):
            out += ".*"
            i += 2
        elif pattern[i] == "*":
            out += "[^/]*"
            i += 1
        else:
            out += re.escape(pattern[i])
            i += 1
    return re.compile("^" + out + "$")


compiled = []
for a in ann:
    paths = a["path"] if isinstance(a["path"], list) else [a["path"]]
    compiled.append(([rx(p) for p in paths], a))


def license_of(path):
    hit = None
    for rxs, a in compiled:  # later annotations take precedence
        if any(r.match(path) for r in rxs):
            hit = a["SPDX-License-Identifier"]
    return hit


checks = {
    "halow-addon/artifacts/morse.ko": "GPL-2.0-only",
    "halow-addon/artifacts/dot11ah.ko": "GPL-2.0-only",
    "halow-addon/artifacts/mm8108b2-rl.bin": "LicenseRef-Morse-Micro-Binary-Distribution-License-Agreement",
    "halow-addon/artifacts/bcf/bcf_boardtype_0807.bin": "LicenseRef-Morse-Micro-Binary-Distribution-License-Agreement",
    "halow-addon/artifacts/hostapd_s1g": "BSD-3-Clause AND ISC",
    "halow-addon/artifacts/hostapd_cli_s1g": "BSD-3-Clause AND ISC",
    "halow-addon/artifacts/hostapd_s1g.conf": "BSD-3-Clause",
    "halow-addon/third-party-notices/hostap.README.txt": "LicenseRef-Third-Party-License-Texts",
    "halow-addon/icon.png": "LicenseRef-Morse-Micro-Brand-Assets",
    "halow-addon/logo.png": "LicenseRef-Morse-Micro-Brand-Assets",
    "halow-addon/source-offer/kernel-6.18.58-haos.config": "GPL-2.0-only",
    "halow-addon/source-offer/build-modules.sh": "Apache-2.0",
    "halow-addon/source-offer/build-hostapd.sh": "Apache-2.0",
    "halow-addon/Dockerfile": "Apache-2.0",
    "halow-addon/config.yaml": "Apache-2.0",
    "halow-addon/apparmor.txt": "Apache-2.0",
    "halow-addon/translations/en.yaml": "Apache-2.0",
    "halow-addon/README.md": "Apache-2.0",
    "halow-addon/docs/OPERATIONS.md": "Apache-2.0",
    "halow-addon/tests/run_tests.sh": "Apache-2.0",
    "halow-addon/tools/generate_sbom.sh": "Apache-2.0",
    "halow-addon/build.sh": "Apache-2.0",
    "README.md": "Apache-2.0",
}
for p, want in checks.items():
    got = license_of(p)
    assert got == want, "%s maps to %s, expected %s" % (p, got, want)

# Every file under rootfs/ enters the image: all of them must map to Apache-2.0.
base = os.path.join(root, "halow-addon", "rootfs")
n = 0
for dp, _, fns in os.walk(base):
    for fn in fns:
        rel = os.path.relpath(os.path.join(dp, fn), root).replace(os.sep, "/")
        got = license_of(rel)
        assert got == "Apache-2.0", "%s maps to %s" % (rel, got)
        n += 1
assert n > 20, "only %d rootfs files found" % n

# No annotation may point a rootfs path at another license, and every .ko maps to GPL-2.0-only.
for a in ann:
    paths = a["path"] if isinstance(a["path"], list) else [a["path"]]
    for p in paths:
        if "rootfs" in p:
            assert a["SPDX-License-Identifier"] == "Apache-2.0", "rootfs annotation %s" % p
for a in ann:
    paths = a["path"] if isinstance(a["path"], list) else [a["path"]]
    if any(p.endswith(".ko") for p in paths):
        assert a["SPDX-License-Identifier"] == "GPL-2.0-only", "a .ko annotation is not GPL-2.0-only"
print("reuse ok: %d rootfs files, %d annotations" % (n, len(ann)))
PYEOF
assert_success "REUSE.toml parses; kernel modules map to GPL-2.0-only; every rootfs file and the original files map to Apache-2.0; firmware, hostapd and the two brand images map to LicenseRef ids" python3 -I "${TMPDIR:-/tmp}/reuse_check.$$.py" "$ROOT"
rm -f "${TMPDIR:-/tmp}/reuse_check.$$.py"
assert_success "REUSE.toml uses only the license ids the repository documents (Apache-2.0, GPL-2.0-only, BSD-3-Clause AND ISC, three LicenseRef ids)" bash -c 'ids="$(grep -E "^SPDX-License-Identifier" "$0" | sed "s/.*= \"//; s/\"$//" | sort -u | paste -sd" ")"; [ "$ids" = "Apache-2.0 BSD-3-Clause BSD-3-Clause AND ISC GPL-2.0-only LicenseRef-Morse-Micro-Binary-Distribution-License-Agreement LicenseRef-Morse-Micro-Brand-Assets LicenseRef-Third-Party-License-Texts" ]' "$ROOT/REUSE.toml"
assert_success "every LicenseRef id in REUSE.toml has its text file in LICENSES/ (the gate checks this too)" bash -c 'for id in $(grep -E "^SPDX-License-Identifier" "$0/REUSE.toml" | grep -oE "LicenseRef-[A-Za-z0-9.-]+" | sort -u); do [ -s "$0/LICENSES/$id.txt" ] || exit 1; done' "$ROOT"

echo "-- nothing relicenses a third-party component --"
DOCS=("$ROOT/README.md" README.md NOTICE THIRD-PARTY-NOTICES.md PROVENANCE.md SOURCE-OFFER.md CHANGELOG.md)
for d in "${DOCS[@]}"; do
    assert_failure "$d does not say everything, the whole image or all components are Apache-2.0" bash -c 'tr "\n" " " < "$0" | tr -s " " | grep -qiE "(everything|all (of )?(the )?(components|files|code|software)|the (whole|entire) (image|repository|product|app)) (in this [a-z]+ )?(is|are) licensed under (the )?Apache"' "$d"
    assert_failure "$d does not say the kernel modules or the firmware are Apache-2.0" bash -c 'tr "\n" " " < "$0" | tr -s " " | grep -qiE "(kernel modules?|driver modules?|firmware|board (data|files?)|hostapd)[^.]{0,80} (are|is) (licensed )?(under )?(the )?Apache"' "$d"
    assert_failure "$d does not say the license has not been chosen or decided" grep -qiE "licen[cs]e (has|have) not been (chosen|decided)|no licen[cs]e (is|has been) chosen|licen[cs]e: not decided" "$d"
done
assert_success "the texts in LICENSES/ are exactly those of the ids REUSE.toml uses" bash -c '[ "$(ls "$0" | paste -sd" ")" = "$1" ]' LICENSES "$LIC_SET"

echo "-- the license files are tracked and are copied into the image --"
assert_failure "no .gitignore line ignores LICENSE, NOTICE, LICENSES, THIRD-PARTY-NOTICES.md or REUSE.toml" bash -c 'cat .gitignore "$0/.gitignore" 2>/dev/null | grep -vE "^[[:space:]]*(#|$)" | grep -qE "LICEN[SC]E|NOTICE|REUSE"' "$ROOT"
assert_success "the Dockerfile copies the staged license files into /usr/share/licenses/morse_micro_halow_ap in one layer" grep -qxF 'COPY legal-stage/ /usr/share/licenses/morse_micro_halow_ap/' Dockerfile
assert_success ".dockerignore admits only the Dockerfile, the manifest, artifacts/, rootfs/ and the staged license files" bash -c '[ "$(grep -vE "^[[:space:]]*(#|$)" .dockerignore | grep -E "^!" | paste -sd" ")" = "!Dockerfile !MANIFEST.sha256 !artifacts/ !rootfs/ !legal-stage/" ]'

echo "test_license_treatment: $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed"
exit $([ "$HALOW_TEST_FAILURES" -eq 0 ] && echo 0 || echo 1)
