# Corresponding source for the bundled components

The app image bundles components under licenses that require source to be provided with the
binaries: two GPL-2.0-only kernel modules, statically linked LGPL libraries, and GPL, LGPL and MPL
packages of the Alpine Linux base. This document says how that source is provided, which
shipped file each part corresponds to, and what was checked. It is a statement of facts and
not a legal conclusion.

## How the source is provided

The corresponding source for version 1.0.0 is provided as **release assets** of the release `v1.0.0`
of this repository, not in the Git history, because the archives are large. The set is attached
to the release when the release is made, and every asset is then available at an address of the
form:

`https://github.com/MorseMicroLabs/home-assistant-halow/releases/download/v1.0.0/<asset name>`

Every asset name, size and SHA-256 is recorded in `source-assets/ASSETS.psv`, which is also in
the image at `/usr/share/licenses/morse_micro_halow_ap/source-assets/`. The repository file
`source-assets/PUBLICATION-STATUS` records whether the set has been attached to the release and
checked from outside (`tools/final_publication_check.sh`). The assets include the
file `SHA256SUMS`, so a downloaded set is verified with `sha256sum -c SHA256SUMS`. The index
`SOURCE-INDEX.md` is itself an asset.

| Asset | What it is |
|---|---|
| `SOURCE-INDEX.md` | index of the assets and of which shipped file each one corresponds to |
| `SHA256SUMS` | checksums of every other asset |
| `morse-driver-source-2.1.0.tar.gz` | the Morse Micro driver (`morse.ko`, `dot11ah.ko`) at commit `4ce0a0272f8ac8e2fa58eea8ff08116e493399de`, with the rate-control submodule at `24f6c69dc9b78490b75cd181ad7013c1b3c3def6` filled in |
| `kernel-module-build-material-1.0.0.tar.xz` | the kernel configuration the modules were built against, its `Module.symvers`, the nine Home Assistant Operating System 18.4 kernel patches, the base configuration and fragments, the toolchain configuration, the build scripts and the log of the kernel tree preparation |
| `kernel-prep.sh` | the script that prepared the kernel tree (the same file as `source-offer/kernel-prep.sh`) |
| `linux-6.18.58.tar.xz` | the upstream Linux 6.18.58 kernel source, unchanged |
| `haos-operating-system-18.4.tar.gz` | the Home Assistant Operating System 18.4 source archive, unchanged (patches and configurations) |
| `buildroot-d2b75e05.tar.gz` | the Home Assistant Buildroot fork at commit `d2b75e0548bf1f0c56d17cac44d5fe9a0e17e60a`, which builds the cross toolchain |
| `hostap-source-2.1.0.tar.gz` | the Morse Micro hostap fork at commit `e7309b438eaec4b82f2db29e8ef7beaca3ca52c6` (`hostapd_s1g`, `hostapd_cli_s1g`) |
| `hostapd-relink-material-1.0.0.tar.xz` | object files, static libraries, link commands and a relink script that rebuild the two executables from their parts, so the statically linked LGPL libraries can be replaced |
| `libnl-3.11.0.tar.gz` | the libnl 3.11.0 source (LGPL-2.1), unchanged |
| `glibc-2.41-5dd252cf.tar.gz` | the GNU C Library source at the commit the toolchain build used (LGPL-2.1-or-later) |
| `alpine-3.23-copyleft-sources-1.0.0.tar` | for each Alpine package in the image whose license requires source: the package build file at the recorded aports commit, its patches and local files, and the upstream source archives, each checked against the checksum in the build file |

The assets stay available at these addresses for as long as version 1.0.0 is offered for download,
and for at least three years after the last time it is offered.

## Which shipped file each part corresponds to

- **`morse.ko` and `dot11ah.ko` (GPL-2.0-only):** the driver source asset, the kernel build
  material, the kernel and Operating System sources, the Buildroot source and `kernel-prep.sh`.
  `source-offer/build-modules.sh` builds the two modules from them and compares the result with
  `MANIFEST.sha256`.
- **`hostapd_s1g` and `hostapd_cli_s1g` (BSD-3-Clause AND ISC, statically linked with glibc and
  libnl under the LGPL, and with OpenSSL under Apache-2.0):** the hostap source asset,
  `source-offer/build-hostapd.sh`, the relink material, and the libnl and glibc sources.
- **Alpine packages (GPL, LGPL, MPL):** the Alpine source asset. Its `INDEX.tsv` lists every
  origin, version and the image packages built from it.
- **Firmware and board file:** these are supplied under the Morse Micro Binary Distribution
  License Agreement and are binary files; there is no source for them in this release.

The full-image inventory, with the license, verification level and redistribution record of
every component, is `provenance.psv` and `PROVENANCE.md`. `source_disposition.psv` says, for
every component, whether its source is in the assets, is not required, or is referenced only.

## What is not in the assets, and why

- Permissively licensed components (for example OpenSSL under Apache-2.0, the s6 programs, bashio,
  jemalloc, tempio and its Go modules, Python, and the Alpine packages whose licenses are MIT, BSD,
  ISC and similar) are not included, because their licenses do not require source to be provided
  with binaries. Where a package offers a permissive alternative to a copyleft license (dbus,
  libcap, zstd), the permissive alternative is used and the source is not included. The exact
  upstream versions, commits and checksums are recorded in `provenance.psv`; the OpenSSL release
  tarball used for the static library is named, with its checksum, in `source-offer/build-hostapd.sh`.
- The GCC 13.4.0 runtime code linked into the executables is under the GCC Runtime Library
  Exception, which allows distribution of the combined binary without its source; whether this
  build qualifies for the exception was not independently verified. The Alpine `gcc` source (for
  `libgcc` and `libstdc++` in the image) is in the Alpine asset.
- The cross compiler itself is a build tool and is not part of the image. Its configuration and
  the Buildroot source are in the assets; the toolchain was reused for these builds, not rebuilt
  from them.

## What was checked

- **Kernel modules.** The kernel tree for 6.18.58 was prepared on 2026-10-28 by `kernel-prep.sh`
  (exit 0, nine patches applied, tree `.config` SHA-256
  `796504d949af46211a2335632054527a761c39a67d371f78294a5a8d925e48ab`, `Module.symvers` SHA-256
  `83218533c79e6fd3024058cc85bcfda325cc5f6097e5dfc09d2febccbf21dc2c`); a second tree, whose
  preparation was not recorded, has the same two checksums. On 2026-11-18 the two modules were rebuilt with
  `source-offer/build-modules.sh` from an extraction of the driver source asset (with
  `DRIVER_FROM_ARCHIVE=1`, using that prepared tree and the toolchain) and both printed `MATCH`
  against `MANIFEST.sha256` (`morse.ko` `bafaafb2...`, `dot11ah.ko` `73535f72...`). Earlier, four
  builds with the driver, kernel tree and toolchain at different locations gave identical
  modules. Both modules carry vermagic `6.18.58-haos SMP preempt mod_unload aarch64` and every
  undefined symbol resolves against the tree's `Module.symvers`. They loaded and ran on one Home
  Assistant Green running Home Assistant OS 18.4 (kernel 6.18.58-haos) in live tests on
  2026-10-30 and 2026-10-31; this is evidence from one device.
- **hostapd.** `build-hostapd.sh` was run twice, from different directories, from a clean clone of
  the hostap commit, a checksum-verified OpenSSL 3.5.9 tarball and the toolchain; both runs
  printed `MATCH` for `hostapd_s1g` and `hostapd_cli_s1g` against `MANIFEST.sha256`. The hostap
  source asset was shown to equal that commit tree (`diff -r`), and on 2026-11-18 the script was run
  once more with `HOSTAP_FROM_ARCHIVE=1` from an extraction of the asset alone, with the same result.
  The libnl static libraries were built from the libnl source asset plus one Buildroot patch for a
  header copy (`package/libnl/0001-Add-musl-workaround-to-the-libc-compat.h-copy.patch`, in the
  Buildroot asset); no Buildroot patch was applied to glibc, and OpenSSL was built from its
  unmodified release tarball. The relink
  material was then extracted into a fresh directory and `relink.sh` rebuilt both executables from
  it with only the toolchain; both are byte-identical to the shipped files, and a link trace
  showed that every library and start file came from the archive.
- **Alpine sources.** Every upstream archive, patch and local source file in the Alpine asset was
  checked against the `sha512sums` of its build file at the recorded aports commit; the build files
  and maintainer scripts themselves come from that commit without a checksum.
- **Upstream files.** The kernel tarball checksum equals the line in kernel.org's published list
  (the list's OpenPGP signature was checked with a key fetched from kernel.org that is not
  certified through a trust path). The Operating System archive is the GitHub archive of tag `18.4`,
  commit `4a7dab478abc8f959c0fc2c24876d08282a3c060`, and contains the nine patches by checksum.

## Limits that remain

- **Kernel tree.** The 6.18.58 tree is not byte-identical to the official 18.4 build: the toolchain
  commit differs (the local toolchain is Buildroot `d2b75e05`; the official 18.4 kernel banner names
  `-g30c038aa`; GCC 13.4.0 and binutils 2.43.1 in both), and the cfg80211, mac80211 and libarc4
  modules built in the local tree have different build-ids from the published 18.4 host modules.
  The kernel does not check symbol versions here (`CONFIG_MODVERSIONS` is not set), so the checks
  at load time are the vermagic and the module format, which match. The final configuration differs
  from the configuration derived from the official 18.4 image in exactly one line,
  `CONFIG_CC_VERSION_TEXT`.
- **Toolchain.** The toolchain was built by hand from the Buildroot source and a configuration that
  differs from what `green_defconfig` regenerates in static libraries and PIE and RELRO settings
  (listed in `corresponding_source.psv`); a rebuild of the toolchain from the stored configuration
  was not done.
- **Relinking.** Relinking with the unmodified libraries was proven. Relinking with a modified
  `libc.a` or libnl was not tried.
- **Reproducibility.** The shipped modules and executables reproduce byte for byte from the recorded
  inputs on the build machine. The container image as a whole is not claimed to be bit-for-bit
  reproducible, and is not expected to be: build attestations and timestamps differ between builds, and
  some Alpine dependency versions are not pinned (a build with no layer cache on 2026-11-18 resolved a
  newer libexpat than an earlier build). The Alpine binaries were not rebuilt from the sources.
- **Per-package notices.** The copyright notices of the individual Alpine packages are not
  reproduced in the image; the generic license texts are in `third-party-notices/spdx/`.
- **Driver license headers.** The driver source files carry SPDX tags of GPL-2.0-or-later while the
  repository license file is the GPL version 2 text and the compiled modules carry the tag
  `Dual BSD/GPL`. The modules are treated as GPL-2.0-only, the more restrictive reading.
- **GPL-3.0 components.** Some Alpine packages (bash, readline, gdbm, libelf and others) are under
  GPL-3.0 or LGPL-3.0 alternatives. They are unmodified Alpine packages whose sources are in the
  Alpine asset; whether the GPL-3.0 "installation information" terms apply to any of them was not
  assessed.
- **Older modules.** The modules built for 6.18.52 (Home Assistant OS 18.3) are no longer bundled.

## Scope

The assets cover the kernel modules, the hostapd programs and their statically linked LGPL libraries,
and the Alpine packages whose licenses require source, with the build material and relinking material
listed above. The GCC 13.4.0 runtime code and the compiler are treated as described under "What is
not in the assets, and why". Components that do not require source are listed, with their upstream
references, in `provenance.psv`, which inventories every component found in the image. This is not a
statement that every Alpine component was rebuilt from these sources, or that the image can be
reproduced bit for bit.
