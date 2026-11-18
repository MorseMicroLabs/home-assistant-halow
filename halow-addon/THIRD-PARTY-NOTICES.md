# Third-Party Notices

This file summarizes the components of the Morse Micro Wi-Fi HaLow Access Point for Home Assistant
by category, with each license exactly as `provenance.psv` records it and the verification status
recorded for it. It is generated from `provenance.psv` by `tools/generate_third_party_notices.py`.
It is a summary of a record, not a legal conclusion. Where a component is not relicensed here,
it keeps the license recorded for it. See `NOTICE` for the license boundary and `PROVENANCE.md`
for how far each entry was checked.

The original application code is licensed under Apache-2.0 (`LICENSE`). The kernel modules,
including the Morse Micro driver, are GPL-2.0-only, unchanged and separate from the application
code. Firmware and board data are under the Morse Micro Binary Distribution License Agreement.

## Verification Status

- `confirmed`: the license text of the pinned source was read from that exact ref.
- `from-bundle-record`: recorded when the artifact was built; not re-read since.
- `apkbuild-confirmed`: the license equals the `license=` line of the package's APKBUILD at the recorded
  aports commit (the packager's statement); the upstream license files were not read.
- `unverified`: not yet checked; the license is the value recorded by the package or image metadata.

Qualifications from `PROVENANCE.md` for `confirmed`: for the firmware and board files, it means the
agreement file exists at the stated path in the pinned commit and its exact text is in `LICENSES/`.
For the hostapd rows, the repository-level license is BSD-3-Clause; one compiled file is dual
GPL-2.0 or ISC and is used under ISC, so the expression is `BSD-3-Clause AND ISC`.

The record has 110 rows: 27 `confirmed`, 80 `apkbuild-confirmed`, 1 `from-bundle-record`, 2 `unverified`.

Redistribution of the components in the record is approved, with each component's existing license
and notices retained (110 of 110 rows are recorded `approved`). The license texts are in `LICENSES/`.

| Category | Rows | confirmed | apkbuild-confirmed | from-bundle-record | unverified |
|---|---|---|---|---|---|
| Bundled artifacts (`artifacts/`) | 7 | 7 | 0 | 0 | 0 |
| Libraries statically linked into the bundled programs | 5 | 4 | 0 | 1 | 0 |
| Base image and components installed outside apk | 17 | 15 | 0 | 0 | 2 |
| Alpine packages (aarch64) | 80 | 0 | 80 | 0 | 0 |
| The app's own files | 1 | 1 | 0 | 0 | 0 |
| Total | 110 | 27 | 80 | 1 | 2 |

## Bundled Artifacts

The files staged in `artifacts/` and copied into the image. The kernel modules are GPL-2.0-only and remain separate from the Apache-2.0 application code.

| File | License as recorded | Verification |
|---|---|---|
| ./morse.ko | GPL-2.0-only | confirmed |
| ./dot11ah.ko | GPL-2.0-only | confirmed |
| ./hostapd_s1g | BSD-3-Clause AND ISC (repository-level license BSD-3-Clause; src/utils/radiotap.c, which is compiled in, is dual GPL-2.0 or ISC and is used under ISC; the radiotap and nl80211 header files are ISC) | confirmed |
| ./hostapd_cli_s1g | BSD-3-Clause AND ISC (as hostapd_s1g) | confirmed |
| ./hostapd_s1g.conf | BSD-3-Clause (repository level; the file's own header says only '# Copyright 2021 Morse Micro') | confirmed |
| ./mm8108b2-rl.bin | Morse Micro Binary Distribution License Agreement | confirmed |
| ./bcf/bcf_boardtype_0807.bin | Morse Micro Binary Distribution License Agreement | confirmed |

## Statically Linked Libraries

Linked into the bundled programs listed above; they have no files of their own.

| Component | License as recorded | Verification |
|---|---|---|
| OpenSSL 3.5.9 (statically linked into hostapd_s1g only) | Apache-2.0 | confirmed |
| GNU C Library 2.41-161-g5dd252cf1d113644b3679f5a158e9ef20217865e, statically linked into hostapd_s1g and hostapd_cli_s1g | LGPL-2.1-or-later | confirmed |
| libnl 3.11.0 (libnl-3 and libnl-genl-3), statically linked into hostapd_s1g | LGPL-2.1-only | confirmed |
| GCC 13.4.0 runtime support library (libgcc), statically linked into the executables | GPL-3.0-or-later WITH GCC-exception-3.1 (GCC Runtime Library Exception) | confirmed |
| MMRC rate-control code (the mmrc submodule of the driver), compiled into morse.ko | GPL-2.0-or-later OR a Morse Micro commercial licence (as that repository states in its LICENSING file and file headers) | from-bundle-record |

## Base Image and Components Installed Outside apk

Components the Home Assistant base image installs. They are not relicensed here.

| Component | License as recorded | Verification |
|---|---|---|
| Home Assistant base image 2026.10.3 (Alpine 3.23.7, aarch64) | composite: no single licence recorded; see the image-package and image-component rows | unverified |
| jemalloc 5.4.0 (libjemalloc.so.2 and its symlink libjemalloc.so, jemalloc-config, jemalloc.sh, jeprof; compiled from source by the base image build, not an apk package; installed by the base image outside apk) | the text of COPYING in jemalloc 5.4.0 (two numbered conditions and a warranty disclaimer; the text names no licence and carries no SPDX identifier); jeprof carries its own notice text (Google Inc., and Andrea Leofreddi for an embedded script) | confirmed |
| /etc/pip.conf, a three-line pip settings file added by the base image | Apache-2.0 at repository level (the LICENSE file of that repository at that commit is the Apache License 2.0 text; the file itself has no licence header) | confirmed |
| /etc/ssl/certs/ca-certificates.crt, the CA certificate bundle (a data file, 178791 bytes, 118 PEM certificate blocks) | MPL-2.0 AND MIT (as the apk metadata of ca-certificates-bundle records it; unverified) | unverified |
| execline 2.9.9.2 (installed by the base image outside apk) | ISC | confirmed |
| s6 2.15.1.0 (installed by the base image outside apk) | ISC | confirmed |
| s6-linux-init 1.2.0.2 (installed by the base image outside apk) | ISC | confirmed |
| s6-linux-utils 2.6.4.1 (installed by the base image outside apk) | ISC | confirmed |
| s6-overlay 3.2.3.2 (installed by the base image outside apk) | ISC | confirmed |
| s6-overlay-helpers 0.1.2.2 (installed by the base image outside apk) | ISC | confirmed |
| s6-portable-utils 2.3.1.2 (installed by the base image outside apk) | ISC | confirmed |
| s6-rc 0.7.0.0 (installed by the base image outside apk) | ISC | confirmed |
| s6-networking 2.8.0.1 (installed by the base image outside apk) | ISC | confirmed |
| skalibs 2.15.1.0 (installed by the base image outside apk) | ISC | confirmed |
| s6-dns 2.4.1.3 (installed by the base image outside apk) | ISC | confirmed |
| tempio 2026.07.0 (installed by the base image outside apk) | Apache-2.0 (the statically linked Go modules are MIT, BSD-3-Clause and Apache-2.0; the Go standard library is BSD-3-Clause; their notices are in third-party-notices/) | confirmed |
| bashio 0.19.0 (installed by the base image outside apk) | MIT | confirmed |

## Alpine Packages

80 packages, as the image's apk database records them. License strings are the package metadata values, checked against the package build file where marked `apkbuild-confirmed`.

| Package | License as recorded | Verification |
|---|---|---|
| alpine-baselayout 3.7.2-r0 (Alpine 3.23 package, aarch64) | GPL-2.0-only | apkbuild-confirmed |
| alpine-baselayout-data 3.7.2-r0 (Alpine 3.23 package, aarch64) | GPL-2.0-only | apkbuild-confirmed |
| alpine-keys 2.6-r0 (Alpine 3.23 package, aarch64) | MIT | apkbuild-confirmed |
| alpine-release 3.23.7-r0 (Alpine 3.23 package, aarch64) | MIT | apkbuild-confirmed |
| apk-tools 3.0.8-r0 (Alpine 3.23 package, aarch64) | GPL-2.0-only | apkbuild-confirmed |
| bash 5.3.3-r1 (Alpine 3.23 package, aarch64) | GPL-3.0-or-later | apkbuild-confirmed |
| bind-libs 9.20.30-r0 (Alpine 3.23 package, aarch64) | MPL-2.0 | apkbuild-confirmed |
| bind-tools 9.20.30-r0 (Alpine 3.23 package, aarch64) | MPL-2.0 | apkbuild-confirmed |
| brotli-libs 1.2.1-r0 (Alpine 3.23 package, aarch64) | MIT | apkbuild-confirmed |
| busybox 1.37.0-r30 (Alpine 3.23 package, aarch64) | GPL-2.0-only | apkbuild-confirmed |
| busybox-binsh 1.37.0-r30 (Alpine 3.23 package, aarch64) | GPL-2.0-only | apkbuild-confirmed |
| c-ares 1.34.9-r0 (Alpine 3.23 package, aarch64) | MIT | apkbuild-confirmed |
| ca-certificates 20261020-r0 (Alpine 3.23 package, aarch64) | MPL-2.0 AND MIT | apkbuild-confirmed |
| ca-certificates-bundle 20261020-r0 (Alpine 3.23 package, aarch64) | MPL-2.0 AND MIT | apkbuild-confirmed |
| curl 8.23.0-r0 (Alpine 3.23 package, aarch64) | curl | apkbuild-confirmed |
| dbus 1.16.2-r1 (Alpine 3.23 package, aarch64) | AFL-2.1 OR GPL-2.0-or-later | apkbuild-confirmed |
| dbus-daemon-launch-helper 1.16.2-r1 (Alpine 3.23 package, aarch64) | AFL-2.1 OR GPL-2.0-or-later | apkbuild-confirmed |
| dbus-libs 1.16.2-r1 (Alpine 3.23 package, aarch64) | AFL-2.1 OR GPL-2.0-or-later | apkbuild-confirmed |
| dnsmasq 2.91-r1 (Alpine 3.23 package, aarch64) | GPL-2.0-or-later | apkbuild-confirmed |
| dnsmasq-common 2.91-r1 (Alpine 3.23 package, aarch64) | GPL-2.0-or-later | apkbuild-confirmed |
| fstrm 0.6.1-r4 (Alpine 3.23 package, aarch64) | MIT | apkbuild-confirmed |
| gdbm 1.26-r0 (Alpine 3.23 package, aarch64) | GPL-3.0-or-later | apkbuild-confirmed |
| gmp 6.3.0-r4 (Alpine 3.23 package, aarch64) | LGPL-3.0-or-later OR GPL-2.0-or-later | apkbuild-confirmed |
| iproute2 6.17.0-r0 (Alpine 3.23 package, aarch64) | GPL-2.0-or-later | apkbuild-confirmed |
| iproute2-minimal 6.17.0-r0 (Alpine 3.23 package, aarch64) | GPL-2.0-or-later | apkbuild-confirmed |
| iproute2-ss 6.17.0-r0 (Alpine 3.23 package, aarch64) | GPL-2.0-or-later | apkbuild-confirmed |
| iproute2-tc 6.17.0-r0 (Alpine 3.23 package, aarch64) | GPL-2.0-or-later | apkbuild-confirmed |
| iptables 1.8.11-r1 (Alpine 3.23 package, aarch64) | GPL-2.0-or-later | apkbuild-confirmed |
| jansson 2.14.1-r0 (Alpine 3.23 package, aarch64) | MIT | apkbuild-confirmed |
| jq 1.8.2-r0 (Alpine 3.23 package, aarch64) | MIT | apkbuild-confirmed |
| json-c 0.18-r1 (Alpine 3.23 package, aarch64) | MIT | apkbuild-confirmed |
| keyutils-libs 1.6.3-r4 (Alpine 3.23 package, aarch64) | GPL-2.0-or-later AND LGPL-2.0-or-later | apkbuild-confirmed |
| kmod 34.2-r1 (Alpine 3.23 package, aarch64) | GPL-2.0-or-later | apkbuild-confirmed |
| krb5-conf 1.0-r2 (Alpine 3.23 package, aarch64) | MIT | apkbuild-confirmed |
| krb5-libs 1.22.1-r0 (Alpine 3.23 package, aarch64) | MIT | apkbuild-confirmed |
| libapk 3.0.8-r0 (Alpine 3.23 package, aarch64) | GPL-2.0-only | apkbuild-confirmed |
| libbz2 1.0.8-r6 (Alpine 3.23 package, aarch64) | bzip2-1.0.6 | apkbuild-confirmed |
| libcap2 2.78-r0 (Alpine 3.23 package, aarch64) | BSD-3-Clause OR GPL-2.0-only | apkbuild-confirmed |
| libcom_err 1.47.3-r0 (Alpine 3.23 package, aarch64) | GPL-2.0-or-later AND LGPL-2.0-or-later AND BSD-3-Clause AND MIT | apkbuild-confirmed |
| libcrypto3 3.5.9-r0 (Alpine 3.23 package, aarch64) | Apache-2.0 | apkbuild-confirmed |
| libcurl 8.23.0-r0 (Alpine 3.23 package, aarch64) | curl | apkbuild-confirmed |
| libelf 0.194-r0 (Alpine 3.23 package, aarch64) | GPL-3.0-or-later AND ( GPL-2.0-or-later OR LGPL-3.0-or-later ) | apkbuild-confirmed |
| libexpat 2.10.0-r0 (Alpine 3.23 package, aarch64) | MIT | apkbuild-confirmed |
| libffi 3.5.2-r0 (Alpine 3.23 package, aarch64) | MIT | apkbuild-confirmed |
| libgcc 15.2.0-r2 (Alpine 3.23 package, aarch64) | GPL-2.0-or-later AND LGPL-2.1-or-later | apkbuild-confirmed |
| libidn2 2.3.8-r0 (Alpine 3.23 package, aarch64) | GPL-2.0-or-later OR LGPL-3.0-or-later | apkbuild-confirmed |
| libmnl 1.0.5-r2 (Alpine 3.23 package, aarch64) | LGPL-2.1-or-later | apkbuild-confirmed |
| libncursesw 6.5_p20251123-r0 (Alpine 3.23 package, aarch64) | X11 | apkbuild-confirmed |
| libnftnl 1.3.0-r0 (Alpine 3.23 package, aarch64) | GPL-2.0-or-later | apkbuild-confirmed |
| libpanelw 6.5_p20251123-r0 (Alpine 3.23 package, aarch64) | X11 | apkbuild-confirmed |
| libpsl 0.21.5-r3 (Alpine 3.23 package, aarch64) | MIT | apkbuild-confirmed |
| libssl3 3.5.9-r0 (Alpine 3.23 package, aarch64) | Apache-2.0 | apkbuild-confirmed |
| libstdc++ 15.2.0-r2 (Alpine 3.23 package, aarch64) | GPL-2.0-or-later AND LGPL-2.1-or-later | apkbuild-confirmed |
| libunistring 1.4.1-r0 (Alpine 3.23 package, aarch64) | GPL-2.0-or-later OR LGPL-3.0-or-later | apkbuild-confirmed |
| libuv 1.52.1-r0 (Alpine 3.23 package, aarch64) | MIT | apkbuild-confirmed |
| libverto 0.3.2-r2 (Alpine 3.23 package, aarch64) | MIT | apkbuild-confirmed |
| libxml2 2.13.9-r1 (Alpine 3.23 package, aarch64) | MIT | apkbuild-confirmed |
| libxtables 1.8.11-r1 (Alpine 3.23 package, aarch64) | GPL-2.0-or-later | apkbuild-confirmed |
| mpdecimal 4.0.1-r0 (Alpine 3.23 package, aarch64) | BSD-2-Clause | apkbuild-confirmed |
| musl 1.2.5-r24 (Alpine 3.23 package, aarch64) | MIT | apkbuild-confirmed |
| musl-utils 1.2.5-r24 (Alpine 3.23 package, aarch64) | MIT AND BSD-2-Clause AND GPL-2.0-or-later | apkbuild-confirmed |
| ncurses-terminfo-base 6.5_p20251123-r0 (Alpine 3.23 package, aarch64) | X11 | apkbuild-confirmed |
| nftables 1.1.5-r2 (Alpine 3.23 package, aarch64) | GPL-2.0-or-later | apkbuild-confirmed |
| nghttp2-libs 1.69.0-r0 (Alpine 3.23 package, aarch64) | MIT | apkbuild-confirmed |
| oniguruma 6.9.10-r0 (Alpine 3.23 package, aarch64) | BSD-2-Clause | apkbuild-confirmed |
| protobuf-c 1.5.2-r2 (Alpine 3.23 package, aarch64) | BSD-2-Clause | apkbuild-confirmed |
| pyc 3.12.16-r0 (Alpine 3.23 package, aarch64) | PSF-2.0 | apkbuild-confirmed |
| python3 3.12.16-r0 (Alpine 3.23 package, aarch64) | PSF-2.0 | apkbuild-confirmed |
| python3-pyc 3.12.16-r0 (Alpine 3.23 package, aarch64) | PSF-2.0 | apkbuild-confirmed |
| python3-pycache-pyc0 3.12.16-r0 (Alpine 3.23 package, aarch64) | PSF-2.0 | apkbuild-confirmed |
| readline 8.3.1-r0 (Alpine 3.23 package, aarch64) | GPL-3.0-or-later | apkbuild-confirmed |
| scanelf 1.3.8-r2 (Alpine 3.23 package, aarch64) | GPL-2.0-only | apkbuild-confirmed |
| sqlite-libs 3.53.4-r0 (Alpine 3.23 package, aarch64) | blessing | apkbuild-confirmed |
| ssl_client 1.37.0-r30 (Alpine 3.23 package, aarch64) | GPL-2.0-only | apkbuild-confirmed |
| tzdata 2026e-r0 (Alpine 3.23 package, aarch64) | Public-Domain | apkbuild-confirmed |
| userspace-rcu 0.15.3-r0 (Alpine 3.23 package, aarch64) | LGPL-2.1-or-later | apkbuild-confirmed |
| xz 5.8.4-r0 (Alpine 3.23 package, aarch64) | GPL-2.0-or-later AND 0BSD AND Public-Domain AND LGPL-2.1-or-later | apkbuild-confirmed |
| xz-libs 5.8.4-r0 (Alpine 3.23 package, aarch64) | GPL-2.0-or-later AND 0BSD AND Public-Domain AND LGPL-2.1-or-later | apkbuild-confirmed |
| zlib 1.3.2-r1 (Alpine 3.23 package, aarch64) | Zlib | apkbuild-confirmed |
| zstd-libs 1.5.7-r2 (Alpine 3.23 package, aarch64) | BSD-3-Clause OR GPL-2.0-or-later | apkbuild-confirmed |

## The App's Own Files

Licensed under Apache-2.0. See `LICENSE` and `NOTICE`.

| Component | License as recorded | Verification |
|---|---|---|
| The add-on's own files (rootfs/, Dockerfile, config.yaml, services, libraries, status server) | Apache-2.0 (the original application code; the kernel modules are separate files and remain GPL-2.0-only) | confirmed |
