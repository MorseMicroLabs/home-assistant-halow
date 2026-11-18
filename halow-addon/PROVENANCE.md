# Provenance and licences of the bundled artifacts

This is the human-readable companion to `provenance.psv`, which is the machine-checked
record (`tests/test_provenance_manifest.sh` verifies that every file in `MANIFEST.sha256`
has a complete row with the same checksum, and that no row is empty).

**Status: recorded, with redistribution approved.** Every artifact below is tracked for where it
came from and which licence its source declares. **Redistribution is approved** for the components recorded here, `redistribution: approved` on every row, with each
component's existing licence and notices retained. The approval changes no licence, and this file
is not a legal conclusion. The firmware and board files are redistributed complete and unmodified,
with the Morse Micro Binary Distribution License Agreement, whose exact text is
`LICENSES/LicenseRef-Morse-Micro-Binary-Distribution-License-Agreement.txt`. The artifacts are
deliberately not committed to this repository (see `.gitignore`); `build.sh` stages them from a
separately built bundle.

## Current state of this record (version 1.0.0)

This section states the current record and takes precedence over older passages below, which
keep the history of how each fact was established.

- Every row of `provenance.psv` records `redistribution: approved`. The license texts are in
  `LICENSES/` and `third-party-notices/`, which the image carries at
  `/usr/share/licenses/morse_micro_halow_ap/`, together with this file, `provenance.psv`,
  `corresponding_source.psv`, `source_disposition.psv` and the build scripts in `source-offer/`.
- Statuses: `confirmed` means the license file of the pinned upstream source was read at that
  reference and its text is shipped; it is not a finding about every obligation. 27 rows are
  `confirmed` (the seven artifacts, OpenSSL, glibc, libnl, the GCC runtime, the s6 family,
  tempio, bashio, jemalloc, the base-image configuration file and the app's own files
  among them). `apkbuild-confirmed` (the 80 Alpine package rows) means the license equals the
  `license=` line of the package build file at the recorded aports commit; upstream license files
  were not read for those packages. One row is `from-bundle-record` and two are `unverified`
  (the base image as a composite, and the CA bundle's `AND MIT` clause, which was not found
  upstream: the certificate data is MPL-2.0).
- The Alpine packages' own copyright notices are not reproduced. The files in
  `third-party-notices/spdx/` are the generic SPDX license texts, with their placeholder copyright
  lines; the packages' own notices are in their source archives.
- Source: the corresponding source, build material and relink material are provided as release
  assets of version 1.0.0 (`SOURCE-OFFER.md`, `source-assets/ASSETS.psv`, `source-assets/SOURCE-INDEX.md`).
  They cover the two kernel modules, hostapd and its statically linked LGPL libraries, and the Alpine
  packages whose licenses require source. Components whose licenses do not require source are
  inventoried here and not included. This is a statement of coverage, not of bit-for-bit
  reproducibility of the image, and the Alpine binaries were not rebuilt from the sources.
- Coverage: the 110 rows cover every component found in the image. `tools/generate_sbom.sh` checks
  this against the built image: every package, every non-apk component and every bundled artifact
  has a row, and every file that no apk package owns belongs to a known group. How far each row was
  verified differs and is stated per row (`confirmed`, `apkbuild-confirmed`, `from-bundle-record`,
  `unverified`).

## Product license

The original application code (the files under `rootfs/`, the Dockerfile, `config.yaml`,
translations, AppArmor profile, build scripts, tests, tools, and documentation) is licensed under
Apache-2.0 (`LICENSE`, `NOTICE`). The kernel modules, including the Morse Micro driver
(`morse.ko`, `dot11ah.ko`), remain GPL-2.0-only, unchanged and separate from the application code.
Everything else below keeps the license recorded for it; nothing in this record relicenses a
third-party component. `THIRD-PARTY-NOTICES.md` summarizes the 110 rows of `provenance.psv` by
category, and `REUSE.toml` maps paths to licenses for scanners. The statuses below (`confirmed`,
`apkbuild-confirmed`, `from-bundle-record`, `unverified`) are unchanged by this: the product license is a decision, not
a verification of any third-party license.

## What is bundled

| Artifact | From | Pinned at | Licence declared by that source |
|---|---|---|---|
| `morse.ko`, `dot11ah.ko` | Morse Micro `morse_driver` | commit `4ce0a0272f8ac8e2fa58eea8ff08116e493399de` | GPL-2.0-only (the repository's `LICENSE` is GNU GPL v2) |
| `hostapd_s1g`, `hostapd_cli_s1g`, `hostapd_s1g.conf` | Morse Micro `hostap` fork | tag `mm8108-2.1.0`, commit `e7309b438eaec4b82f2db29e8ef7beaca3ca52c6` (the same release as the bundled driver and firmware) | BSD-3-Clause (the repository's `COPYING` says the BSD option only has applied since 2012) |
| `mm8108b2-rl.bin` | Morse Micro `morse-firmware` | commit `ce39cefb5fd01ad689a0c0b043557d9c2a3167d8`, `firmware/` | Morse Micro Binary Distribution License Agreement (a proprietary binary licence) |
| `bcf/bcf_boardtype_0807.bin` | Morse Micro `morse-firmware` | the same commit, `bcf/morsemicro/` | the same agreement |
| MMRC rate-control code (git submodule of the driver, compiled into `morse.ko`) | `mm_rate_control`, a submodule of `morse_driver` | commit `24f6c69dc9b78490b75cd181ad7013c1b3c3def6` | GPL-2.0-or-later, or a Morse Micro commercial licence (that repository's `LICENSING`; recorded in `corresponding_source.psv`, not re-read in the 2026-10-28 pass) |
| OpenSSL 3.5.9 (inside `hostapd_s1g` only) | OpenSSL release 3.5.9 | tarball SHA-256 `603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a` | Apache-2.0 |
| glibc 2.41-161-g5dd252cf (inside `hostapd_s1g` and `hostapd_cli_s1g`) | GNU C Library, the source the Buildroot package selects | commit `5dd252cf1d113644b3679f5a158e9ef20217865e` | LGPL-2.1-or-later |
| libnl 3.11.0 (inside `hostapd_s1g`) | libnl release tarball | SHA-256 `2a56e1edefa3e68a7c00879496736fdbf62fc94ed3232c0baba127ecfa76874d` | LGPL-2.1-only |
| libgcc, GCC 13.4.0 runtime (inside the executables) | the Home Assistant Buildroot fork | commit `d2b75e0548bf1f0c56d17cac44d5fe9a0e17e60a` | GPL-3.0-or-later with the GCC Runtime Library Exception |

All checksums are in `MANIFEST.sha256` and `provenance.psv`.

## How far each licence entry was checked

- **Confirmed** (the licence file of the pinned commit was read): the driver (GNU GPL v2),
  `hostap` (`COPYING` and `README`, read at the 2.1.0 tag; both are identical to those of the earlier 1.17.9 tag the add-on used before), and the firmware and BCF files (the
  Binary Distribution License Agreement exists at the stated path in that commit; its exact
  text is copied unchanged into `LICENSES/`, and the two license files in the commit are byte-identical).
- **Confirmed for `hostapd_s1g` and `hostapd_cli_s1g`:** `COPYING` and `README` of the tag state
  BSD-3-Clause for the repository (copyright 2002-2024 Jouni Malinen and contributors; the GPL
  option was dropped in 2012). Of the 251 source and header files of the compiled set (derived
  with `make -n` on a native compiler, not the cross toolchain), 244 carry the standard BSD wording.
  `src/common/morse/morse_commands.h` carries only a copyright line and is covered by the
  repository-level licence; `src/utils/radiotap.c` is dual GPL-2.0 or ISC and is used under ISC
  (the ISC text is in `radiotap.h`); the radiotap and nl80211 header files are ISC. No GPL-only or
  other copyleft file is in the compiled set. The licence expression is therefore
  `BSD-3-Clause AND ISC`; the notices are in `third-party-notices/`.
- **OpenSSL:** the Apache-2.0 LICENSE of the 3.5.9 release tarball was read and is in `third-party-notices/`.
- **C library, GCC runtime and netlink library (statically linked):** their license texts (glibc
  `COPYING.LIB` and `LICENSES`, GCC `COPYING3` and `COPYING.RUNTIME`, libnl `COPYING`) were read at the
  pinned sources and are in `third-party-notices/`. Whether this build qualifies for the GCC Runtime
  Library Exception was not verified.
- **Module licence tag (inventory item):** both kernel modules carry the tag `Dual BSD/GPL`
  (read from the rebuilt binaries with `modinfo`).
- "Confirmed" means the licence file at the pinned commit was opened and its identity
  checked during this work; no per-file hash of those licence files is recorded here.
- Checked against upstream sources only for `nftables` and the four runtime libraries it brought in (below). The other operating-system packages in the container (the 80 apk packages) and the base image's non-apk programs are recorded in `provenance.psv`; the apk packages are marked `apkbuild-confirmed` (see the current state above), and the s6 family, tempio and bashio were later read at their upstream tags.

## Things to know before any distribution

- The two kernel modules are GPL code built for one specific Home Assistant OS kernel
  release. They were rebuilt on 2026-10-28 for Home Assistant OS 18.4 (kernel `6.18.58-haos`),
  replacing the 6.18.52 builds (`morse.ko` `bafaafb2...`, `dot11ah.ko` `73535f72...`, in
  `MANIFEST.sha256`). What is **not** byte-identical: the cross toolchain is the Buildroot
  commit `d2b75e05`, not the `30c038aa` that built the 18.4 image (same GCC and binutils
  versions), and the `cfg80211`, `mac80211` and `libarc4` modules built in the local kernel tree
  have different GNU build-ids from the published 18.4 host modules. The rebuilt modules were
  checked off-device (vermagic, symbol resolution, four identical builds) and were
  loaded on one Green (Home Assistant OS 18.4, kernel 6.18.58-haos) in a live test on 2026-10-30; they will not load on a
  different kernel. `SOURCE-OFFER.md` and `corresponding_source.psv` record the exact module
  source, kernel patches and configuration, toolchain and build script they were built from
  (four rebuilds at different locations gave identical modules); the source itself is in the release
  assets, and the modules were rebuilt from the driver source asset on 2026-11-18 with matching results.
- The firmware and BCF files are under a vendor binary licence, not an open-source one.
  Which BCF file is needed depends on the adapter's own board identifier; only the one for
  the validated Australian unit is bundled.
- Both executables are statically linked. `hostapd_s1g` contains OpenSSL (Apache-2.0; its LICENSE is in
  `third-party-notices/`); both contain the C library and the compiler runtime, and
  `hostapd_s1g` also contains the netlink libraries (LGPL). The versions are recorded above; their license
  texts were read and are in `third-party-notices/`, and the relink material is the release asset
  `hostapd-relink-material-1.0.0.tar.xz` (relinking with the unmodified libraries was proven).
- The two executables (`hostapd_s1g`, `hostapd_cli_s1g`) are shipped stripped with the
  build toolchain's own strip and contain no build-machine path strings (searched for the
  build user's name, home directory, workspace and temporary directories; the only `/tmp` string left is the runtime socket name
  template `/tmp/wpa_ctrl_%d-%d` in `hostapd_cli_s1g`). The unstripped,
  path-mapped builds are not part of this tree; they still carry paths of the prebuilt
  toolchain archives in their debug information, which is why only the stripped files
  are shipped. The kernel modules are still not stripped and carry debug information (the
  module build script maps the build paths in its default mode); that part was not
  re-audited here and stays a release check, not something the image build hides.
- Licence texts in the image: the image built on 2026-10-28 carried only
  `/usr/share/licenses/libuv/LICENSE` and `/usr/lib/python3.12/LICENSE.txt` (from the Python package).
  Since the 1.0.0 image, the product's license files, the license texts and notices of the bundled
  components, this record and the source-asset manifest are in
  `/usr/share/licenses/morse_micro_halow_ap/` (see "Current state of this record" above).
- `hostapd_s1g.conf` is the vendor sample with changes; it inherits the `hostap` licence.
- **hostap release line.** Earlier development builds of the add-on bundled `hostapd_s1g` and
  `hostapd_cli_s1g` built from the older `hostap` tag `1.17.9` (commit
  `beed5f8c827fa4b6dc77ec9d467c84cdee50fdda`) together with a separate `morse_cli` helper from
  the same older line, next to a driver and firmware from release `mm8108-2.1.0`. They are now
  built from `hostap` tag `mm8108-2.1.0`, the release that matches the driver and firmware,
  and `morse_cli` is no longer bundled: this `hostapd_s1g` talks to the driver over nl80211
  vendor commands (it contains no `morse_cli` string), so no helper program is needed. The
  tag does not build with its own `-Werror` setting (an unused variable at
  `src/ap/ap_config.c:849` when WPS is off and HS20 is on); it was built with
  `-Wno-error=unused-variable`, which changes no behavior. The vendor defconfig of this tag
  enables `CONFIG_DRIVER_NL80211_MORSE` and `CONFIG_MORSE_5GHZ_MAPPED`; DPP, DPP2, DPP3 and OWE
  stay disabled as before. The build recipe is `source-offer/build-hostapd.sh` and the source
  pin is in `corresponding_source.psv`. The files Morse Micro added in this release carry a
  copyright line but no licence text in their headers; nothing beyond that was assessed. These
  exact (path-neutral, stripped) binaries were run on one Home Assistant Green running Home Assistant OS 18.4 in a
  bounded smoke test on 2026-10-31: the access point started on AU 8 MHz channel 43 with
  WPA3-SAE and protected management frames, and one client associated. The same source,
  built unstripped, passed a longer live test on the same device.

## Scope: what this record covers and what it does not

**Covered:** the seven staged artifact files in `artifacts/` (listed in `MANIFEST.sha256`) and
the third-party libraries statically linked into the executables among them (OpenSSL, the C
library, the netlink library, the GCC runtime) and the rate-control code compiled into the
driver module. The image's own packages and components are inventoried as `image-package:` and
`image-component:` rows (below). The corresponding-source record (`SOURCE-OFFER.md`,
`corresponding_source.psv`, `source_disposition.psv`) covers the kernel modules, hostapd with its
statically linked LGPL libraries, and the Alpine packages whose licenses require source.

**Not covered — dependencies of the container image, not artifacts:** the base image
(`ghcr.io/home-assistant/base`), the packages the `Dockerfile` installs (`iproute2`,
`iptables`, `nftables`, `dnsmasq`, `kmod`, `dbus`, and `python3` for the status page) and everything those
bring in are runtime dependencies, not bundled artifacts: separate third-party software with
their own licences. They are not part of the checksummed artifact set, but since 2026-10-28
they are **inventoried** in `provenance.psv` (rows `image-package:` and `image-component:`) from
the image built by `build.sh`, and the whole image can be listed with `tools/generate_sbom.sh`
(see "Image inventory and SBOM" below). The base image is pinned by digest in the `Dockerfile` and the seven
packages are pinned to exact Alpine 3.23 versions; the packages they pull in as dependencies are
not pinned individually: the base image digest fixes only the packages the base image already
carries (50), and the roughly 30 others the install adds are resolved from the live Alpine 3.23
repository at build time, so a later or Supervisor-side build may pick different revisions
(on 2026-10-30 the resulting 80-package set was identical to the previous image's). An exact pin
can only be rebuilt while the Alpine repository still serves that version.
**Depth of verification (as of 1.0.0):** every image row is inventoried. The licence of the 80 Alpine
packages is the packager's statement, checked against the package build file at the recorded aports
commit (`apkbuild-confirmed`), not against the upstream license files, except the five packages
checked against upstream on 2026-10-25. The source that the licenses require is in the release
assets (`SOURCE-OFFER.md`); nothing here is a statement that the image can be reproduced bit for bit.

## Image inventory and SBOM

The facts below were first recorded from an image built on 2026-10-28 and re-measured on 2026-10-31
from the 0.4.0-rc.1 image built with `BUILD_IMAGE=1 ./build.sh` on the refreshed base (tag
`morse-micro-halow-ap:0.4.0-rc.1`, linux/arm64; nothing was pushed). It contains:

- the base image `ghcr.io/home-assistant/base:3.23` at digest
  `sha256:1550b137f45bbb61f932a5ec97265c1d8594ddc4a986b127fb06a5c8c4bcaa6d` (Alpine 3.23.7,
  base image version 2026.10.3; it replaced the earlier pin `sha256:746e2e52831a0c99154427f4af99cbd5ed4f3ca9f55995eb2f6a5e2cbd6ecbb0`, version 2026.10.0, Alpine 3.23.6, on 2026-10-31; the base image's build file differs between those two tags only in running `apk upgrade` before `apk add`, and the non-apk programs it installs (s6-overlay family, tempio, bashio, jemalloc, `/etc/pip.conf`) are byte-identical in the two images);
- **80 Alpine packages** in the apk database (all recorded in `provenance.psv`, with version,
  licence as the package metadata states it, and the aports build commit);
- **14 programs installed outside apk by the base image**: the s6-overlay 3.2.3.2
  distribution (s6 2.15.1.0, s6-rc 0.7.0.0, s6-linux-init 1.2.0.2, s6-linux-utils 2.6.4.1,
  s6-portable-utils 2.3.1.2, s6-overlay-helpers 0.1.2.2, execline 2.9.9.2, skalibs 2.15.1.0,
  s6-dns 2.4.1.3, s6-networking 2.8.0.1), tempio 2026.07.0, bashio 0.19.0 (the version the
  base image's build file names; the image itself states none), and jemalloc 5.4.0 (see below).
  Their licenses are not recorded in the image; they were read at the upstream tags and are `confirmed`
  (s6 family ISC, tempio Apache-2.0 with its Go modules, bashio MIT, jemalloc as below);
- one configuration file the base image adds (`/etc/pip.conf`, row `image-component:base-image-config`);
- the CA certificate bundle `/etc/ssl/certs/ca-certificates.crt` (row `image-component:ca-bundle`): a data
  file, not a program, that the apk database lists under the package `ca-certificates-bundle` and that
  is understood to be refreshed by the `ca-certificates` package trigger (not run or inspected here); its
  SHA-256 and size are recorded, its licence is the package metadata value (`unverified`), redistribution is
  `approved` and no source is held;
- the seven bundled artifacts and the add-on's own files.

Facts worth noting: the image carries the dynamic OpenSSL libraries `libcrypto3` and `libssl3`
3.5.9 (an Alpine package dependency, used by `curl`) as well as the OpenSSL 3.5.9 that is statically
linked into `hostapd_s1g` (separate copies, built separately); the Alpine package licence strings include copyleft licences
(GPL-2.0-only, GPL-2.0-or-later, GPL-3.0-or-later, LGPL variants), permissive licences and several
`OR` and `AND` combinations that this record does not resolve.

**jemalloc (found in the base image on 2026-10-30).** The base image carries the memory
allocator library jemalloc, which is not an apk package. The base image's build file (file
`alpine/Dockerfile` of `https://github.com/home-assistant/docker-base` at its tag `2026.10.3`,
commit `aac55b5055f542a99d99f8bb9872fbe01de427e2`, SHA-256
`d153da3ef4358f5b7d93b5f753825c9f3c5ef22ff5cf36649b0b2f957a0bf0be`; the jemalloc, s6-overlay, tempio and bashio steps are identical to tag `2026.10.0`, commit `ba8e9382ebfa6f5507269a1d4db853200f25fd3e`, file SHA-256 `fd7354ec63f94ca4f350242e03c1072c102a5b13af8209659288fef3556656a8`, on which the first reading was made) clones the jemalloc git
repository at tag `5.4.0` (commit `7a34f18502e7b222724097cdcd499b437d189acc`), runs `autogen.sh
--with-lg-page=16`, and installs the shared library and the helper programs into `/usr/local`.
The image does not state the version: the library and `jemalloc-config` print the placeholder
`0.0.0-0-g000000missing_version_try_git_fetch_tags`, because the build used a checkout without
tags. The version is therefore inferred from the base image's build file; the shipped `jeprof` equals the
upstream script of that tag after configure substitution. The installed files are
`/usr/local/lib/libjemalloc.so.2` (SHA-256 `b0454c6af4498f9fd5b775c6674c5fa7dc4257ee8b1cdf1debfc5a030614a7fb`;
the symlink `libjemalloc.so` points to it), `/usr/local/bin/jemalloc-config`, `/usr/local/bin/jemalloc.sh`
and `/usr/local/bin/jeprof`; no header file, manual page, licence file or notice file for it is installed. The upstream release
tarball (`https://github.com/jemalloc/jemalloc/releases/download/5.4.0/jemalloc-5.4.0.tar.bz2`) has SHA-256
`200776fac271093e7c2f21edd6d62657ecd2be578d9328633f2a86bfa6ef4f1d`; the base image's build file states no checksum.
The licence text is the file `COPYING` (SHA-256 `94aa2caa98c25d942f58b956c71dba6a99ff98fc3a31cbc669fe2a4cd0268b53`,
identical at the tagged commit and in the tarball): copyright lines for Jason Evans (2002-present), the
Mozilla Foundation (2007-2012) and Facebook, Inc. (2009-present), and two numbered conditions (keep the
copyright notice, conditions and disclaimer in source redistributions; reproduce them in the documentation
or other materials of binary redistributions) followed by a warranty disclaimer. The text does not give
the licence a name. The `jeprof` script carries its own notice texts (Google Inc., 1998-2007, with a
third condition about the use of names; and Andrea Leofreddi, 2009-2010, for an embedded script). What
these texts require of this image has not been assessed.

Relationship to the add-on: no program in the image is linked against jemalloc (all 517 ELF files in the
image were read with `readelf`; none lists `libjemalloc` as a needed library); the image environment sets no
`LD_PRELOAD` or `MALLOC_CONF`, there is no `/etc/ld.so.preload`, and nothing in the image runs
`jemalloc.sh`. `hostapd_s1g` and `hostapd_cli_s1g` are statically linked and contain no jemalloc;
`python3` and the other programs use the allocator of the musl C library. The library is present in the
image but is not loaded by any program in it as built.

**Checksums read from the image.** For what the image itself contains, `tools/generate_sbom.sh`
measures the value and compares it with the row, so a row cannot simply restate itself: the SHA-256 of
`/usr/bin/tempio`, of the jemalloc library, of `/etc/pip.conf` and of the CA bundle, and a tree digest
for each s6 part and for bashio. A tree digest is the SHA-256 of the sorted `sha256sum` list (lines of
hash, two spaces, path relative to the image root, sorted byte-wise by path) of the regular files under
a stated path set; symlinks and directories are not covered. The path set of an s6 part is its
`/package/<category>/<name>-<version>` directory (for `s6-overlay` also `/init`, `/etc/s6-overlay` and
`/etc/fix-attrs.d`), and for bashio `/usr/lib/bashio`; field 2 of those rows holds the digest, not a
file hash. The generator also hashes every file under `/opt/halow/artifacts` in the image and compares
the files with the artifact rows (path and checksum) in both directions and with the image's own
`MANIFEST.sha256`. The `embedded:` rows have no file: the generator requires exactly the five expected
rows and checks a library-specific byte string in the carrier file for four of them; the versions of
OpenSSL, glibc and libnl are not stated by the stripped static executables and libnl has no string at all,
so those facts come from the build record only. The apk packages carry no sha256 by design: the
checksum the apk database holds (the `C:` and `Z:` entries) is a SHA-1 based value and not a SHA-256, so
the rows record it only as the "apk database checksum". Upstream references for what the base image
downloads come from its build file (tags `2026.10.0` and `2026.10.3`, identical for these steps): the s6-overlay 3.2.3.2 release tarballs and the
checksum files published beside them (recorded in the `image-component:s6-overlay` row), the `tempio`
2026.07.0 release asset (the SHA-256 of the file in the image equals the digest the GitHub release API
lists for it), and the bashio 0.19.0 release archive (no checksum recorded). The s6 tarballs and the
bashio archive were not downloaded or compared with the image trees.

**Completeness check of the image.** The files of the image that no apk package owns were listed
and each belongs to one row: the s6-overlay tree under `/package` with its `/command` and
`/usr/bin` symlinks and `/init` (the s6 family rows), `tempio`, bashio under `/usr/lib/bashio`,
the four jemalloc files and the library symlink, `/etc/pip.conf`, the add-on's own files, links
created by installed packages (busybox applets, certificate hash links), and the package
manager's and container runtime's own state files. Nothing else was found. Every ELF file
in the image is either in an apk package, in the s6-overlay tree, `tempio`, the jemalloc library, or a
bundled artifact (the firmware and board files carry an ELF header and were included).
`tests/test_sbom_completeness.sh` checks the form of this record (and, on fixtures, the
generator's cross-check) and `tools/generate_sbom.sh` compares the SBOM with `provenance.psv`
in both directions on a real image; `source_disposition.psv` records, for each bundled artifact
and embedded library, where its corresponding source is recorded or that none is.

**Licence summary of the image components** (values as the licence text or the record states
them; nothing here is a legal conclusion):

| Component | Version | Licence as recorded | Where that value comes from | Check |
|---|---|---|---|---|
| jemalloc (library and helper programs) | 5.4.0 (from the base image's build file) | the text of `COPYING`: two numbered conditions, no licence name in the text; `jeprof` also carries Google Inc. and Andrea Leofreddi notice texts | `COPYING` and `bin/jeprof.in` at the pinned tag | confirmed (text read at the pinned commit) |
| s6-overlay and the other nine s6, skarnet and execline programs | see rows | ISC (read at the upstream tags) | copies in `third-party-notices/` | confirmed |
| tempio | 2026.07.0 | Apache-2.0 (the Go modules it links are MIT, BSD-3-Clause and Apache-2.0) | copies in `third-party-notices/` | confirmed |
| bashio | 0.19.0 (from the base image's build file) | MIT | copy in `third-party-notices/` | confirmed |
| `/etc/ssl/certs/ca-certificates.crt` | not applicable (data file of `ca-certificates-bundle` 20261020-r0) | MPL-2.0 AND MIT (apk metadata of the owning package) | the installed apk database | unverified |
| `/etc/pip.conf` | not applicable | Apache-2.0 at repository level (no header in the file) | the `LICENSE` file of the base image repository at its tag | confirmed (repository level) |
| the 80 Alpine packages | per row | the package metadata value (equal to the package build file) | the installed apk database | apkbuild-confirmed (five also checked against upstream) |
| the base image as a whole | 2026.10.3 | composite | see the rows | unverified |

`tools/generate_sbom.sh [IMAGE [OUTDIR]]` reads a built image (it runs the image once with the
network disabled and changes nothing) and writes the package list, the non-apk components, a
licence summary and a CycloneDX JSON file. The output of the latest run (2026-10-31) is held outside
this repository and is not part of the checksummed artifact set. The SBOM is an inventory, not
a licence verification and not a legal conclusion.

`nftables` (added for the firewall's read-only probe of the INPUT base chain; pinned `nftables=1.1.5-r2`)
is recorded like `iptables`: a licence-bearing Alpine package. Since 2026-10-28 it has an
`image-package:` row in `provenance.psv`; it has no row in `corresponding_source.psv`; its source is in the Alpine release asset (see `SOURCE-OFFER.md`). The
detail below is the prose record. The facts below were checked on
2026-10-25 against public sources only. They are a factual record, not a legal conclusion.

**nftables 1.1.5-r2 (Alpine 3.23).** The installed package's metadata says licence
`GPL-2.0-or-later`, homepage `https://netfilter.org/projects/nftables`, aports build commit
`3ad6ddd15d7322059aee9635ad917b7875b1c676`. That commit's `main/nftables/APKBUILD`
(`https://git.alpinelinux.org/aports/plain/main/nftables/APKBUILD?id=3ad6ddd15d7322059aee9635ad917b7875b1c676`;
the `3.23-stable` branch carries the same pkgver 1.1.5, pkgrel 2) declares
`license="GPL-2.0-or-later"` and the source `https://netfilter.org/projects/nftables/files/nftables-1.1.5.tar.xz`
with sha512 `01fbbea43fd01250b0176a200dfdb6b84d3d51156cc2350acb25a5e66960e1908c3d17a0363baddb32897ea8bea0569b67500a94f708c8587b0e29402f51cbb6`.
That tarball was downloaded and hashed: SHA-256 `1daf10f322e14fd90a017538aaf2c034d7cc1eb1cc418ded47445d714ea168d4`
(equal to the `.sha256sum` that upstream publishes at
`https://www.netfilter.org/projects/nftables/files/nftables-1.1.5.tar.xz.sha256sum`) and the sha512 above
(equal to the APKBUILD's). The upstream `.sig` signature was not verified.
**Licence, upstream versus Alpine:** upstream's `COPYING` in that tarball is the GNU GPL version 2 text
preceded by a statement that the original author distributed the code under GPL version 2 *only*, and that
new code is moving to GPL version 2 or any later. The source files reflect that mix (headers in `src/` and
`include/` use both "version 2 as published" and "version 2 (or any later)" wording; a few files carry a
`GPL-2.0-or-later` SPDX tag and most have none). So `GPL-2.0-or-later` for the whole package, as Alpine
classifies it, is **not** supported by upstream's own statement; the authoritative upstream position is
GPL-2.0, original code version 2 only, newer code version 2 or later. For compliance purposes this
record treats the package as GPL-2.0 (the stricter reading).

**New runtime dependencies.** Installed versions and licence strings are from the built image's apk
database. The sources are the `3.23-stable` branch APKBUILDs under
`https://git.alpinelinux.org/aports/plain/main/<package>/APKBUILD?h=3.23-stable`; each tarball was
downloaded and its sha512 equals the APKBUILD's.

| Package | Licence (apk metadata = APKBUILD) | Source archive | SHA-256 (computed) | Upstream checksum |
|---|---|---|---|---|
| libnftnl 1.3.0-r0 | GPL-2.0-or-later (`COPYING` is GPL v2; most files carry the or-later SPDX tag, three have none) | `https://netfilter.org/projects/libnftnl/files/libnftnl-1.3.0.tar.xz` | `0f4be47a8bb8b77a350ee58cbd4b5fae6260ad486a527706ab15cfe1dd55a3c4` | matches upstream `.sha256sum` |
| libmnl 1.0.5-r2 | LGPL-2.1-or-later (`COPYING` is LGPL 2.1; source headers say 2.1 or any later) | `https://www.netfilter.org/projects/libmnl/files/libmnl-1.0.5.tar.bz2` (plus Alpine's `musl-fix-headers.patch`) | `274b9b919ef3152bfb3da3a13c950dd60d6e2bcd54230ffeca298d03b40d0525` | matches upstream `.sha256sum` |
| jansson 2.14.1-r0 | MIT (upstream `LICENSE`) | `https://github.com/akheron/jansson/releases/download/v2.14.1/jansson-2.14.1.tar.gz` | `2521cd51a9641d7a4e457f7215a4cd5bb176f690bc11715ddeec483e85d9e2b3` | none found; APKBUILD sha512 only |
| gmp 6.3.0-r4 | LGPL-3.0-or-later OR GPL-2.0-or-later (upstream README: LGPL v3 or later, or GPL v2 or later, or both) | `https://gmplib.org/download/gmp/gmp-6.3.0.tar.xz` (plus Alpine's `gcc15.patch`) | `a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898` | none compared; APKBUILD sha512 only |

`readline` 8.3.1-r0 (GPL-3.0-or-later) and `libncursesw` were already in the base image and are not new.

**What the image carries:** none of these packages installs a licence text or notice file (the image's
only `/usr/share/licenses` entry is `libuv`); (as of 2026-10-25). The image now carries the license texts, the source records and the build scripts, and the source is in the release assets.

**Terms as the licence texts read (not legal advice, not assessed):** GPL-2.0 for `nft` and `libnftnl` (and `gmp`,
if that option is taken): the licence text describes conditions on distributing the binaries that include
providing the licence text and the corresponding source or a written offer (the exact terms, including any
offer period, have not been assessed). LGPL-2.1 (`libmnl`) and LGPL-3.0 (`gmp`):
licence text and library source, and the ability to replace the library (whether dynamic linking,
as Alpine builds them, satisfies this has not been assessed). MIT (`jansson`): the copyright and
permission notice must accompany copies. Whether publishing an image is a distribution of these packages
by the project, and which licence alternative applies, is a legal judgement that has not been made.

**OPEN ITEMS (written 2026-10-25; items 1 and 5 were partly closed by the current state above, the rest remain open):**
1. The generic license texts for nftables, libnftnl, libmnl, jansson and gmp are now shipped (`third-party-notices/spdx/`); their own per-package copyright notices are not.
2. (Closed.) The source of these GPL/LGPL packages, and of iptables, busybox and the other Alpine packages
   whose licenses require it, is in the release asset `alpine-3.23-copyleft-sources-1.0.0.tar`.
3. The upstream signatures were not verified, and gmp's and jansson's tarballs were not compared with an
   upstream checksum, so their provenance rests on the APKBUILD sha512 only.
4. The patches Alpine applies (libmnl `musl-fix-headers.patch`, gmp `gcc15.patch`, nftables
   `systemd-service-etc-nftables-nft.patch`) live in aports and are in the Alpine source asset.
5. The other transitive dependencies of the image are still not pinned individually (the base
   image digest fixes only the 50 packages the base already carries; the others are resolved at build time). They are catalogued since 2026-10-28 (rows in `provenance.psv`), but
   their licences are `apkbuild-confirmed` and, where a license requires it, their source is in the Alpine source asset.
