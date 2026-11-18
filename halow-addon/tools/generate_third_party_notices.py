#!/usr/bin/env python3
"""Generate THIRD-PARTY-NOTICES.md from provenance.psv.

Usage: tools/generate_third_party_notices.py [PROVENANCE_PSV] > THIRD-PARTY-NOTICES.md

The table is produced mechanically: license strings and verification statuses are copied
exactly as provenance.psv records them, and no status is changed. tests/test_license_treatment.sh
regenerates the file and requires it to equal the committed THIRD-PARTY-NOTICES.md.
"""
import sys
from collections import Counter

path = sys.argv[1] if len(sys.argv) > 1 else "provenance.psv"
rows = []
with open(path, encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        f = [x.strip() for x in line.split("|")]
        if len(f) != 10:
            sys.exit("provenance.psv: row with %d fields: %s" % (len(f), f[0]))
        rows.append(dict(zip(("path", "sha", "component", "source", "ref", "license",
                              "text", "check", "redist", "notes"), f)))


def cat(r):
    p = r["path"]
    if p.startswith("./"):
        return "artifact"
    if p.startswith("embedded:"):
        return "embedded"
    if p.startswith("image-package:"):
        return "package"
    if p == "image-component:addon-own-code":
        return "own"
    if p.startswith("image-component:"):
        return "component"
    sys.exit("unknown row kind: " + p)


def esc(s):
    return s.replace("|", "\\|")


by = {k: [r for r in rows if cat(r) == k] for k in ("artifact", "embedded", "component", "package", "own")}
counts = Counter(r["check"] for r in rows)
out = []
w = out.append
w("# Third-Party Notices")
w("")
w("This file summarizes the components of the Morse Micro Wi-Fi HaLow Access Point for Home Assistant")
w("by category, with each license exactly as `provenance.psv` records it and the verification status")
w("recorded for it. It is generated from `provenance.psv` by `tools/generate_third_party_notices.py`.")
w("It is a summary of a record, not a legal conclusion. Where a component is not relicensed here,")
w("it keeps the license recorded for it. See `NOTICE` for the license boundary and `PROVENANCE.md`")
w("for how far each entry was checked.")
w("")
w("The original application code is licensed under Apache-2.0 (`LICENSE`). The kernel modules,")
w("including the Morse Micro driver, are GPL-2.0-only, unchanged and separate from the application")
w("code. Firmware and board data are under the Morse Micro Binary Distribution License Agreement.")
w("")
w("## Verification Status")
w("")
w("- `confirmed`: the license text of the pinned source was read from that exact ref.")
w("- `from-bundle-record`: recorded when the artifact was built; not re-read since.")
w("- `apkbuild-confirmed`: the license equals the `license=` line of the package's APKBUILD at the recorded")
w("  aports commit (the packager's statement); the upstream license files were not read.")
w("- `unverified`: not yet checked; the license is the value recorded by the package or image metadata.")
w("")
w("Qualifications from `PROVENANCE.md` for `confirmed`: for the firmware and board files, it means the")
w("agreement file exists at the stated path in the pinned commit and its exact text is in `LICENSES/`.")
w("For the hostapd rows, the repository-level license is BSD-3-Clause; one compiled file is dual")
w("GPL-2.0 or ISC and is used under ISC, so the expression is `BSD-3-Clause AND ISC`.")
w("")
w("The record has %d rows: %d `confirmed`, %d `apkbuild-confirmed`, %d `from-bundle-record`, %d `unverified`." % (
    len(rows), counts["confirmed"], counts["apkbuild-confirmed"], counts["from-bundle-record"], counts["unverified"]))
w("")
w("Redistribution of the components in the record is approved, with each component's existing license")
w("and notices retained (%d of %d rows are recorded `approved`). The license texts are in `LICENSES/`." % (
    sum(1 for r in rows if r["redist"] == "approved"), len(rows)))
w("")
w("| Category | Rows | confirmed | apkbuild-confirmed | from-bundle-record | unverified |")
w("|---|---|---|---|---|---|")
labels = (("artifact", "Bundled artifacts (`artifacts/`)"),
          ("embedded", "Libraries statically linked into the bundled programs"),
          ("component", "Base image and components installed outside apk"),
          ("package", "Alpine packages (aarch64)"),
          ("own", "The app's own files"))
for k, label in labels:
    c = Counter(r["check"] for r in by[k])
    w("| %s | %d | %d | %d | %d | %d |" % (label, len(by[k]), c["confirmed"], c["apkbuild-confirmed"], c["from-bundle-record"], c["unverified"]))
w("| Total | %d | %d | %d | %d | %d |" % (len(rows), counts["confirmed"], counts["apkbuild-confirmed"], counts["from-bundle-record"], counts["unverified"]))
w("")


def table(title, intro, items, first):
    w("## " + title)
    w("")
    if intro:
        w(intro)
        w("")
    w("| %s | License as recorded | Verification |" % first)
    w("|---|---|---|")
    for r in items:
        name = r["path"] if r["path"].startswith("./") else r["component"]
        w("| %s | %s | %s |" % (esc(name), esc(r["license"]), r["check"]))
    w("")


table("Bundled Artifacts", "The files staged in `artifacts/` and copied into the image. The kernel modules are "
      "GPL-2.0-only and remain separate from the Apache-2.0 application code.", by["artifact"], "File")
table("Statically Linked Libraries", "Linked into the bundled programs listed above; they have no files of their own.",
      by["embedded"], "Component")
table("Base Image and Components Installed Outside apk", "Components the Home Assistant base image installs. "
      "They are not relicensed here.", by["component"], "Component")
table("Alpine Packages", "%d packages, as the image's apk database records them. License strings are the package "
      "metadata values, checked against the package build file where marked `apkbuild-confirmed`." % len(by["package"]), by["package"], "Package")
table("The App's Own Files", "Licensed under Apache-2.0. See `LICENSE` and `NOTICE`.", by["own"], "Component")
sys.stdout.write("\n".join(out).rstrip("\n") + "\n")
