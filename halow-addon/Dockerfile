# Morse Micro Wi-Fi HaLow Access Point for Home Assistant: version 1.0.0 (Stable).
# Target: Home Assistant Green (aarch64) only.
# https://contributors.home-assistant.io/apps/guides/dockerfile/
#
# Base image: a fixed FROM pinned by digest (no build argument can replace it, and the
# Supervisor no longer passes one by default). The digest is the Alpine 3.23 Home Assistant
# base image this app was built and tested with.
FROM ghcr.io/home-assistant/base:3.23@sha256:1550b137f45bbb61f932a5ec97265c1d8594ddc4a986b127fb06a5c8c4bcaa6d

# Runtime packages, each pinned to an exact Alpine 3.23 version:
#   iproute2  ip, bridge and ss (the bridge, addresses, routes, socket checks)
#   iptables  iptables/ip6tables and their -restore/-save tools (the app's firewall chains)
#   nftables  the nft program, used read-only: `nft list chain ... INPUT` tells whether the
#             INPUT base chain exists, so the app removes only one it created itself (it
#             never adds, changes or deletes anything through nft)
#   dnsmasq   DHCP and DNS for the HaLow clients
#   kmod      modprobe/insmod/rmmod/lsmod/modinfo (driver loading, compatibility check)
#   dbus      dbus-send only, to talk to the host's NetworkManager over the host_dbus mount;
#             no bus daemon is started
#   python3   the status page service (standard library only)
# Exact pins are reproducible only while the Alpine repository still serves these exact
# versions; Alpine removes superseded package versions, after which this build fails at
# this step instead of silently installing something else. Packages pulled in as
# dependencies are not pinned individually (nftables brings in gmp and jansson, and the
# libraries libmnl and libnftnl it shares with iptables). The answer for customers is a prebuilt, tagged
# image, not a rebuild from this file.
# In the same step: the install log (it holds the install time) and the random machine id
# the dbus package generates are removed, so two builds of the same inputs do not differ
# by them (dbus-send talking to the host's system bus does not use a local machine id;
# unverified on the device); and the setuid bit the dbus package sets on its
# bus-activation helper is removed (no bus daemon runs here), so the build adds no setuid
# program.
RUN apk add --no-cache \
    iproute2=6.17.0-r0 \
    iptables=1.8.11-r1 \
    nftables=1.1.5-r2 \
    dnsmasq=2.91-r1 \
    kmod=34.2-r1 \
    dbus=1.16.2-r1 \
    python3=3.12.16-r0 \
    && rm -f /var/log/apk.log /etc/machine-id /var/lib/dbus/machine-id \
    && chmod u-s,g-s /usr/libexec/dbus-daemon-launch-helper

# The unprivileged user the status page server runs as (fixed ids, no login shell, no home
# directory created). The server's launcher starts as root, reads the Ingress port and then
# drops to this user; the server holds no capabilities. No setuid or file-capability binary
# is added to the image.
# The account is locked (no password); the "last password change" day adduser records is
# cleared so that builds on different days produce the same file.
RUN addgroup -S -g 990 halowstatus \
    && adduser -S -D -H -h /var/empty -s /sbin/nologin -u 990 -G halowstatus halowstatus \
    && sed -i -E 's/^(halowstatus:!):[0-9]+:/\1::/' /etc/shadow

# Stop budget (see README.md, "Stopping"): how long s6 waits at shutdown for the services
# to stop (the manager rolls the host back on its way down), then for stragglers before
# killing them. The Supervisor's own `timeout` in config.yaml (120 s) is larger than the
# sum, so s6 finishes before the Supervisor kills the container.
ENV S6_SERVICES_GRACETIME=90000 \
    S6_KILL_GRACETIME=5000

# Artifacts must already be staged and checksum-verified by ./build.sh before `docker
# build` runs — see build.sh, MANIFEST.sha256 and PROVENANCE.md. This file only copies what
# build.sh verified; it does not build the driver or hostapd. MANIFEST.sha256 is
# a runtime dependency: the firmware and board file are re-checked against it at start.
COPY artifacts/ MANIFEST.sha256 /opt/halow/artifacts/

# The app's own files: services (manager, status), libraries, data tables and the status
# server.
COPY rootfs /

# The license, notices and license texts that must accompany the app and its bundled
# components, at the conventional read-only path for license files in an image: the
# Apache-2.0 application license (LICENSE), the notice (NOTICE), the third-party component
# summary (THIRD-PARTY-NOTICES.md), the source record (SOURCE-OFFER.md, PROVENANCE.md and the
# three .psv records), the build scripts and configurations the source record names
# (source-offer/), the license texts (LICENSES/) and the verbatim notices of third-party
# components (third-party-notices/) and the manifest of the source release assets
# (source-assets/ASSETS.psv, SOURCE-INDEX.md). build.sh gathers them into legal-stage/ so that they
# arrive in ONE layer: every layer lengthens the root overlay line of the container's mount
# table, and the BusyBox mount the app uses reads that table with a bounded line buffer.
COPY legal-stage/ /usr/share/licenses/morse_micro_halow_ap/

# Normalise ownership and modes. COPY keeps the modes of the build context, and a context
# on some file systems (a Windows drive mounted into WSL, for example) shows every file and
# directory as world-writable; that would let the unprivileged status user rewrite code the
# manager runs as root. So: the parent directories COPY touched go back to 0755, every
# app directory is 0755 and every app file 0644 (the license files under
# /usr/share/licenses/morse_micro_halow_ap included), owned by root; only the service
# scripts (run, finish), the start-up hardening scripts in /etc/cont-init.d (run by s6 as
# root before any service; they restrict the saved container environment, which holds the
# Supervisor token, to root) and the two bundled programs are executable.
RUN chmod 0755 /etc /usr /usr/lib /usr/share /usr/share/licenses /opt \
    && chown -R root:root /etc/services.d /etc/cont-init.d /usr/lib/halow /usr/share/halow /usr/share/licenses/morse_micro_halow_ap /opt/halow \
    && find /etc/services.d /etc/cont-init.d /usr/lib/halow /usr/share/halow /usr/share/licenses/morse_micro_halow_ap /opt/halow -type d -exec chmod 0755 {} + \
    && find /etc/services.d /etc/cont-init.d /usr/lib/halow /usr/share/halow /usr/share/licenses/morse_micro_halow_ap /opt/halow -type f -exec chmod 0644 {} + \
    && find /etc/services.d -type f \( -name run -o -name finish \) -exec chmod 0755 {} + \
    && find /etc/cont-init.d -type f -exec chmod 0755 {} + \
    && chmod 0755 \
    /opt/halow/artifacts/hostapd_s1g \
    /opt/halow/artifacts/hostapd_cli_s1g

# Image labels: version, source, title and description. Checked by tests/verify_image.sh on the built image.
LABEL \
    io.hass.type="app" \
    io.hass.version="1.0.0" \
    io.hass.arch="aarch64" \
    org.opencontainers.image.version="1.0.0" \
    org.opencontainers.image.source="https://github.com/MorseMicroLabs/home-assistant-halow" \
    org.opencontainers.image.title="Morse Micro Wi-Fi HaLow Access Point for Home Assistant" \
    org.opencontainers.image.description="Wi-Fi HaLow access point for the Morse Micro Wi-Fi HaLow USB Network Adapter on Home Assistant Green (aarch64). Region: Australia only."
