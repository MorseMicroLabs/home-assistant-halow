# Source index for Morse Micro Wi-Fi HaLow Access Point for Home Assistant 1.0.0

This index belongs to the corresponding-source assets of release `v1.0.0`. It says what each asset
is and which shipped file it corresponds to. Verify a downloaded set with
`sha256sum -c SHA256SUMS`. The repository file `halow-addon/SOURCE-OFFER.md` describes the
mechanism and what was checked; `halow-addon/source-assets/ASSETS.psv` lists the name, size and
SHA-256 of every asset.

## Assets

| Asset | Contents | Corresponds to | License |
|---|---|---|---|
| `morse-driver-source-2.1.0.tar.gz` | Morse Micro driver at commit `4ce0a0272f8ac8e2fa58eea8ff08116e493399de` with the rate-control submodule (`24f6c69dc9b78490b75cd181ad7013c1b3c3def6`) in `mmrc-submodule/` | `morse.ko`, `dot11ah.ko` | GPL-2.0-only (rate control: GPL-2.0-or-later or a Morse Micro commercial license) |
| `kernel-module-build-material-1.0.0.tar.xz` | kernel `.config`, `Module.symvers`, official 18.4 kernel configuration, nine kernel patches, base configuration and fragments, toolchain configuration, build scripts, preparation log, README | `morse.ko`, `dot11ah.ko` | GPL-2.0-only and the licenses of the included upstream files |
| `kernel-prep.sh` | the script that prepared the kernel tree | `morse.ko`, `dot11ah.ko` | Apache-2.0 |
| `linux-6.18.58.tar.xz` | upstream Linux 6.18.58 source, unchanged | kernel the modules were built against | GPL-2.0-only |
| `haos-operating-system-18.4.tar.gz` | Home Assistant Operating System 18.4 source archive, unchanged | kernel patches and configuration | Apache-2.0 and the licenses of its parts |
| `buildroot-d2b75e05.tar.gz` | Home Assistant Buildroot fork at commit `d2b75e0548bf1f0c56d17cac44d5fe9a0e17e60a` | toolchain used for the modules and the executables | GPL-2.0-or-later |
| `hostap-source-2.1.0.tar.gz` | Morse Micro hostap fork at commit `e7309b438eaec4b82f2db29e8ef7beaca3ca52c6` | `hostapd_s1g`, `hostapd_cli_s1g` | BSD-3-Clause AND ISC |
| `hostapd-relink-material-1.0.0.tar.xz` | object files, static libraries, link commands, relink script | `hostapd_s1g`, `hostapd_cli_s1g` (static glibc and libnl) | LGPL-2.1 for the libraries; BSD-3-Clause AND ISC and Apache-2.0 for the rest |
| `libnl-3.11.0.tar.gz` | libnl 3.11.0 source, unchanged | statically linked libnl | LGPL-2.1-only |
| `glibc-2.41-5dd252cf.tar.gz` | GNU C Library source at the commit the toolchain used | statically linked glibc | LGPL-2.1-or-later |
| `alpine-3.23-copyleft-sources-1.0.0.tar` | per Alpine package origin: build file, patches, local files and upstream archives; `INDEX.tsv` and `README.md` at its root | Alpine packages whose license requires source | GPL, LGPL, MPL (per origin) |
| `SOURCE-INDEX.md` | this file | | |
| `SHA256SUMS` | checksums of every other asset | | |

## Shipped file to source

| Shipped file | Source and build material |
|---|---|
| `morse.ko`, `dot11ah.ko` | driver source, kernel build material, kernel, Operating System source, Buildroot source, `kernel-prep.sh`; build and compare with `source-offer/build-modules.sh` (set `DRIVER_FROM_ARCHIVE=1`) |
| `hostapd_s1g`, `hostapd_cli_s1g` | hostap source, `source-offer/build-hostapd.sh`, relink material, libnl and glibc sources |
| Alpine packages | `alpine-3.23-copyleft-sources-1.0.0.tar` (see its `INDEX.tsv`) |
| `mm8108b2-rl.bin`, `bcf_boardtype_0807.bin` | binary files under the Morse Micro Binary Distribution License Agreement; no source |

## Not included

Components whose licenses do not require source with the binaries are not included: OpenSSL
(Apache-2.0; the release tarball and its checksum are named in `source-offer/build-hostapd.sh`),
the s6 programs, bashio, jemalloc, tempio and its Go modules, Python, and the Alpine packages
under MIT, BSD, ISC and similar licenses. The cross compiler is a build tool, not part of the image.

## What was verified, and its limits

- The two modules were rebuilt from the driver source asset on 2026-11-18 and match the shipped
  files. The kernel tree and toolchain used were prepared on 2026-10-28; the toolchain was reused,
  not rebuilt from the assets.
- `hostapd_s1g` and `hostapd_cli_s1g` were rebuilt twice from a clean clone, once from the hostap source
  asset alone (`HOSTAP_FROM_ARCHIVE=1`), and relinked from the relink material; the results are
  byte-identical to the shipped files. The libnl static libraries include one Buildroot header patch
  (in the Buildroot asset). Relinking with modified
  libraries was not tried.
- The kernel tarball checksum equals the line in kernel.org's `sha256sums.asc` fetched on
  2026-11-18, whose OpenPGP signature verified as a good signature of the "Kernel.org checksum
  autosigner" key (fingerprint `B886 8C80 BA62 A1FF FAF5 FDA9 632D 3A06 589D A6B1`, fetched from
  kernel.org, not certified through a trust path); the tarball's own detached signature was not
  checked.
- Every upstream archive and patch in the Alpine asset was checked against the checksum in its
  build file. The Alpine binaries were not rebuilt, and the container image as a whole is not claimed
  to be bit-for-bit reproducible.
