#!/usr/bin/env bash
# Rebuilds the two kernel modules bundled with this add-on (morse.ko and dot11ah.ko) from
# their pinned source and compares the result with this add-on's MANIFEST.sha256.
#
# This script rebuilds the bundled binaries from the pinned inputs: the path-independent mode
# (PATH_INDEPENDENT=1, the default) was run four times at different driver, kernel-tree and
# toolchain locations against a Linux 6.18.58 tree and gave identical modules (see
# ../SOURCE-OFFER.md). It does NOT build the kernel tree or the cross toolchain it needs: those
# are prerequisites, described and pinned in ../SOURCE-OFFER.md and ../corresponding_source.psv
# (the build inputs of the 6.18.58 tree are also printed by this script, see below). Both must
# already exist at the paths below (override with the environment variables).
#
# Build-path independence. The modules carry debug information, and without further flags they
# embed the absolute path of the driver directory, of the kernel tree and of the cross
# toolchain's compiler include directory. By default (PATH_INDEPENDENT=1) this script maps those
# paths out with -ffile-prefix-map (to /build/morse_driver, /build/linux and /build/toolchain),
# so the same sources, kernel tree contents and toolchain are intended to give identical
# modules at any location. PATH_INDEPENDENT=0 selects the legacy mode, which embeds the real
# paths; the modules shipped for Home Assistant OS 18.3 (kernel 6.18.52) were built that way and
# are no longer bundled. The default flipped from 0 to 1 in the same change that updated
# MANIFEST.sha256 to the 6.18.58 modules.
# What was actually tested (off-device, 2026-10-28): builds with PATH_INDEPENDENT=1 against the
# 6.18.58 tree with the driver directory, the kernel tree and the toolchain at different
# locations gave identical morse.ko and dot11ah.ko. Not tested: a different machine, a
# different compiler build, or a kernel tree re-extracted from the tarball. The script never
# changes MANIFEST.sha256; it only compares with it.
#
# Environment: WORK, TOOLCHAIN_BIN, KERNEL_TREE, DRIVER_DIR (locations), PATH_INDEPENDENT
# (1 default, path-independent; 0 legacy).
#
# The build inputs for Home Assistant OS 18.4 (recorded as constants and printed on every run):
#   kernel source    Linux 6.18.58, linux-6.18.58.tar.xz, 154851680 bytes, SHA-256 069b19f9...b818013
#                    (equal to the line kernel.org's sha256sums.asc lists; that file's OpenPGP
#                    signature was not verified)
#   OS source        operating-system tag 18.4, commit 4a7dab478abc8f959c0fc2c24876d08282a3c060,
#                    GitHub archive 18.4.tar.gz, 342411 bytes, SHA-256 7d9f23cf...b85cd (the
#                    archive hash identifies one download; the commit id is the stable identifier)
#   patches          nine, applied with git apply in this order: the three in
#                    buildroot-external/patches/linux/6.18.58 (ipv6, vlan, Bluetooth btusb), then
#                    the six in board/nabucasa/green/patches/linux (hashes: ../corresponding_source.psv)
#   configuration    the kernel configuration derived from the official 18.4 kernel image
#                    (decompressed config.gz, SHA-256 a4426c77...aac4c) was installed and
#                    olddefconfig run; the result (stored as kernel-6.18.58-haos.config,
#                    SHA-256 796504d9...e48ab) differs from the derived one in exactly one
#                    line, CONFIG_CC_VERSION_TEXT
#   toolchain        Buildroot fork commit d2b75e05, GCC 13.4.0, binutils 2.43.1. The 18.4 image's own
#                    compiler reports Buildroot commit 30c038aa (same GCC and binutils versions):
#                    the toolchain commit DIFFERS from the one that built the 18.4 image.
#
# Usage: ./build-modules.sh            (run inside WSL2 or Linux; changes nothing outside $WORK)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$SCRIPT_DIR/../MANIFEST.sha256"

WORK="${WORK:-$HOME/work}"
TOOLCHAIN_BIN="${TOOLCHAIN_BIN:-$WORK/br-output/host/bin}"
KERNEL_TREE="${KERNEL_TREE:-$WORK/linux-6.18.58}"
DRIVER_DIR="${DRIVER_DIR:-$WORK/morse_driver}"
PATH_INDEPENDENT="${PATH_INDEPENDENT:-1}"

DRIVER_URL="https://github.com/MorseMicro/morse_driver.git"
DRIVER_COMMIT="4ce0a0272f8ac8e2fa58eea8ff08116e493399de"
DRIVER_SUBMODULE_COMMIT="24f6c69dc9b78490b75cd181ad7013c1b3c3def6"   # mmrc-submodule

# Build inputs of the kernel tree for Home Assistant OS 18.4 (recorded; see the header).
KERNEL_VERSION="6.18.58"
KERNEL_RELEASE="6.18.58-haos"
KERNEL_TARBALL_SHA256="069b19f9032c4dac8149ae4b6520c35debca0f42a9f6d52ee55ba6ca9b818013"
KERNEL_TARBALL_BYTES="154851680"
OS_TAG="18.4"
OS_TAG_COMMIT="4a7dab478abc8f959c0fc2c24876d08282a3c060"
OS_ARCHIVE_SHA256="7d9f23cfe96e88a2d3aeb9cde33cb0f7005c3a343a11db05b54e231c886b85cd"
OS_ARCHIVE_BYTES="342411"
OFFICIAL_CONFIG_SHA256="a4426c779010b70d480504acc70948c3363960d2d0a5fe1fba1c32cd3b1aac4c"
FINAL_CONFIG_SHA256="796504d949af46211a2335632054527a761c39a67d371f78294a5a8d925e48ab"
TOOLCHAIN_COMMIT="d2b75e0548bf1f0c56d17cac44d5fe9a0e17e60a"
IMAGE_TOOLCHAIN_COMMIT_ABBREV="30c038aa"

echo "Recorded build inputs (Home Assistant OS $OS_TAG, kernel $KERNEL_VERSION):"
echo "  kernel source   linux-$KERNEL_VERSION.tar.xz  $KERNEL_TARBALL_BYTES bytes  sha256 $KERNEL_TARBALL_SHA256"
echo "  OS source       tag $OS_TAG  commit $OS_TAG_COMMIT"
echo "                  archive 18.4.tar.gz  $OS_ARCHIVE_BYTES bytes  sha256 $OS_ARCHIVE_SHA256"
echo "  patches         nine: 3 in buildroot-external/patches/linux/$KERNEL_VERSION, then 6 in board/nabucasa/green/patches/linux (checksums in corresponding_source.psv)"
echo "  configuration   derived from the official 18.4 image: sha256 $OFFICIAL_CONFIG_SHA256"
echo "                  tree .config after olddefconfig:    sha256 $FINAL_CONFIG_SHA256 (differs in exactly one line, CONFIG_CC_VERSION_TEXT)"
echo "  toolchain       Buildroot commit ${TOOLCHAIN_COMMIT:0:8} (the 18.4 image was built with $IMAGE_TOOLCHAIN_COMMIT_ABBREV: not the same commit)"

for p in "$TOOLCHAIN_BIN/aarch64-buildroot-linux-gnu-gcc" "$KERNEL_TREE/Module.symvers" "$KERNEL_TREE/.config"; do
    [ -e "$p" ] || { echo "ERROR: prerequisite missing: $p (see SOURCE-OFFER.md)" >&2; exit 1; }
done
export PATH="$TOOLCHAIN_BIN:$PATH"

# What can be checked about the supplied tree: its kernel release. Its configuration hash is only
# reported, because a tree prepared by other means may legitimately differ.
if [ -f "$KERNEL_TREE/include/config/kernel.release" ]; then
    tree_release="$(cat "$KERNEL_TREE/include/config/kernel.release")"
    [ "$tree_release" = "$KERNEL_RELEASE" ] || { echo "ERROR: the kernel tree is $tree_release, not $KERNEL_RELEASE" >&2; exit 1; }
fi
echo "  tree .config    sha256 $(sha256sum "$KERNEL_TREE/.config" | awk '{print $1}') (as supplied)"

if [ "${DRIVER_FROM_ARCHIVE:-0}" = "1" ]; then
    # DRIVER_DIR is an extraction of morse-driver-source-2.1.0.tar.gz (the driver commit with the
    # rate-control submodule contents in mmrc-submodule/); there is no git history to check.
    [ -f "$DRIVER_DIR/Makefile" ] && [ -n "$(ls -A "$DRIVER_DIR/mmrc-submodule" 2>/dev/null)" ] || { echo "ERROR: $DRIVER_DIR is not a driver source tree with mmrc-submodule filled in" >&2; exit 1; }
else
    if [ ! -d "$DRIVER_DIR/.git" ]; then
        git clone --quiet "$DRIVER_URL" "$DRIVER_DIR"
    fi
    ( cd "$DRIVER_DIR" && git checkout --quiet "$DRIVER_COMMIT" )
    head_commit="$(cd "$DRIVER_DIR" && git rev-parse HEAD)"
    [ "$head_commit" = "$DRIVER_COMMIT" ] || { echo "ERROR: driver is at $head_commit, not $DRIVER_COMMIT" >&2; exit 1; }
    ( cd "$DRIVER_DIR" && git submodule update --init --recursive --quiet )
    sub_commit="$(cd "$DRIVER_DIR" && git submodule status mmrc-submodule | sed -E 's/^[ +-]?([0-9a-f]{40}).*/\1/')"
    [ "$sub_commit" = "$DRIVER_SUBMODULE_COMMIT" ] || { echo "ERROR: mmrc-submodule is at $sub_commit, not $DRIVER_SUBMODULE_COMMIT" >&2; exit 1; }
fi

cd "$DRIVER_DIR"
if [ "$PATH_INDEPENDENT" = "1" ]; then
    # Physical paths, as make and the compiler see them. The toolchain root is the parent of its
    # bin directory (its compiler include directory is recorded in the debug information).
    drv_real="$(pwd -P)"
    krn_real="$(cd "$KERNEL_TREE" && pwd -P)"
    tc_real="$(cd "$TOOLCHAIN_BIN/.." && pwd -P)"
    # The three prefix maps are order-sensitive if one path contains another (GCC prefers the later map).
    export KCFLAGS="${KCFLAGS:-} -ffile-prefix-map=${drv_real}=/build/morse_driver -ffile-prefix-map=${krn_real}=/build/linux -ffile-prefix-map=${tc_real}=/build/toolchain"
elif [ "$PATH_INDEPENDENT" != "0" ]; then
    echo "ERROR: PATH_INDEPENDENT must be 0 or 1" >&2; exit 1
fi
make clean >/dev/null 2>&1 || true
make ARCH=arm64 CROSS_COMPILE=aarch64-buildroot-linux-gnu- \
    -C "$KERNEL_TREE" M="$(pwd)" KERNEL_SRC="$KERNEL_TREE" \
    CONFIG_WLAN_VENDOR_MORSE=m CONFIG_MORSE_USB=y CONFIG_MORSE_USER_ACCESS=y CONFIG_MORSE_VENDOR_COMMAND=y \
    modules

status=0
for pair in "morse.ko:./morse.ko" "dot11ah/dot11ah.ko:./dot11ah.ko"; do
    built="${pair%%:*}"; name="${pair##*:}"
    want="$(awk -v n="$name" '$2 == n {print $1}' "$MANIFEST")"
    got="$(sha256sum "$built" | awk '{print $1}')"
    if [ -n "$want" ] && [ "$got" = "$want" ]; then
        echo "MATCH     $name  $got"
    else
        echo "DIFFERENT $name  built=$got manifest=${want:-none}"
        status=1
    fi
done
exit "$status"
