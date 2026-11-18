#!/usr/bin/env bash
# Prepares the Linux 6.18.58 kernel tree against which the Morse Micro kernel modules
# (morse.ko and dot11ah.ko) of this add-on were built, for Home Assistant OS 18.4
# (kernel release 6.18.58-haos, aarch64).
#
# What it does: verifies the kernel tarball checksum; unpacks it; applies, with git apply, the
# nine kernel patches of the Home Assistant Operating System 18.4 tree (three generic ones
# from buildroot-external/patches/linux/6.18.58, then six for the Green board from
# buildroot-external/board/nabucasa/green/patches/linux, each directory in numeric order);
# installs the kernel configuration derived from the 18.4 kernel image as .config and runs
# olddefconfig; stops if that changes anything other than the compiler text lines; checks that
# the kernel release is 6.18.58-haos; then builds vmlinux and all modules with the cross
# toolchain, which produces Module.symvers; and prints the checksums of the results.
#
# Goal: a tree at $KERNEL_TREE with Module.symvers and .config, so that
# source-offer/build-modules.sh can be run with KERNEL_TREE pointing at it.
#
# History: this script was run on 2026-10-28 with the inputs below (exit 0, nine patches of the
# 18.4 tree applied, "patches found: 9 (expected 9)"). The resulting tree had
# .config SHA-256 796504d949af46211a2335632054527a761c39a67d371f78294a5a8d925e48ab and
# Module.symvers SHA-256 83218533c79e6fd3024058cc85bcfda325cc5f6097e5dfc09d2febccbf21dc2c.
# Only comments and the text of one error message differ from the script that was run.
# The script downloads nothing; all inputs are supplied by the caller.
#
# Inputs (all required):
#   TARBALL          linux-6.18.58.tar.xz (154851680 bytes)
#   EXPECTED_SHA256  069b19f9032c4dac8149ae4b6520c35debca0f42a9f6d52ee55ba6ca9b818013, the
#                    checksum kernel.org publishes for that file (taken from kernel.org's
#                    clearsigned sha256sums.asc; checking that signature with gpg needs the
#                    kernel.org key and is a manual step, not done here)
#   OS_SRC           a checkout of github.com/home-assistant/operating-system at tag 18.4
#                    (commit 4a7dab478abc8f959c0fc2c24876d08282a3c060)
#   OFFICIAL_CONFIG  kernel-18.4.config, the decompressed configuration extracted from the 18.4
#                    kernel image as published on the Home Assistant Operating System GitHub
#                    release (signature chain not verified),
#                    SHA-256 a4426c779010b70d480504acc70948c3363960d2d0a5fe1fba1c32cd3b1aac4c
#   TOOLCHAIN_BIN    directory holding aarch64-buildroot-linux-gnu-gcc (GCC 13.4.0, built from
#                    the Home Assistant Buildroot fork at commit
#                    d2b75e0548bf1f0c56d17cac44d5fe9a0e17e60a)
# Optional: WORK (default $HOME/work184), JOBS (default: all processors), EXPECTED_PATCH_COUNT
# (default 9, the number of patches in the 18.4 tree; if the count in the two directories
# differs, the script stops, so a new or removed patch is never applied or skipped silently).
#
# The script also stops if a patch directory holds a patch in a subdirectory, a file that is
# not named *.patch, or if the checksum, the configuration or the kernel release do not match.
set -euo pipefail
export LC_ALL=C

WORK="${WORK:-$HOME/work184}"
JOBS="${JOBS:-$(nproc)}"
: "${TARBALL:?set TARBALL to linux-6.18.58.tar.xz}"
: "${EXPECTED_SHA256:?set EXPECTED_SHA256 to the kernel.org checksum of the tarball}"
: "${OS_SRC:?set OS_SRC to an operating-system checkout at tag 18.4}"
: "${OFFICIAL_CONFIG:?set OFFICIAL_CONFIG to the extracted 18.4 kernel config}"
: "${TOOLCHAIN_BIN:?set TOOLCHAIN_BIN to the toolchain bin directory}"
KERNEL_TREE="$WORK/linux-6.18.58"
CROSS=aarch64-buildroot-linux-gnu-

[ -x "$TOOLCHAIN_BIN/${CROSS}gcc" ] || { echo "ERROR: no compiler at $TOOLCHAIN_BIN" >&2; exit 1; }
export PATH="$TOOLCHAIN_BIN:$PATH"

got="$(sha256sum "$TARBALL" | awk '{print $1}')"
[ "$got" = "$EXPECTED_SHA256" ] || { echo "ERROR: tarball checksum $got is not $EXPECTED_SHA256" >&2; exit 1; }
[ ! -e "$KERNEL_TREE" ] || { echo "ERROR: $KERNEL_TREE already exists; remove it or set WORK" >&2; exit 1; }
mkdir -p "$WORK"
tar -xf "$TARBALL" -C "$WORK"
[ -f "$KERNEL_TREE/Makefile" ] || { echo "ERROR: tarball did not unpack to $KERNEL_TREE" >&2; exit 1; }

cd "$KERNEL_TREE"
PATCH_DIRS=("$OS_SRC/buildroot-external/patches/linux/6.18.58" "$OS_SRC/buildroot-external/board/nabucasa/green/patches/linux")
EXPECTED_PATCH_COUNT="${EXPECTED_PATCH_COUNT:-9}"
# Count before applying anything: a new patch directory layout must not be skipped silently.
total=0
for dir in "${PATCH_DIRS[@]}"; do
    [ -d "$dir" ] || { echo "ERROR: patch directory not found: $dir" >&2; exit 1; }
    nested="$(find "$dir" -mindepth 2 -name '*.patch' | head -n1)"
    [ -z "$nested" ] || { echo "ERROR: patch below a subdirectory, not applied by this script: $nested" >&2; exit 1; }
    other="$(find "$dir" -maxdepth 1 -type f ! -name '*.patch' | head -n1)"
    [ -z "$other" ] || { echo "ERROR: file in a patch directory that is not a .patch file: $other (inspect it)" >&2; exit 1; }
    total=$((total + $(find "$dir" -maxdepth 1 -type f -name '*.patch' | wc -l)))
done
echo "patches found: $total (expected $EXPECTED_PATCH_COUNT)"
[ "$total" -eq "$EXPECTED_PATCH_COUNT" ] || { echo "ERROR: $total patches found, EXPECTED_PATCH_COUNT is $EXPECTED_PATCH_COUNT; check the list of patches in the tree and set EXPECTED_PATCH_COUNT deliberately" >&2; exit 1; }
for dir in "${PATCH_DIRS[@]}"; do
    for p in $(ls "$dir"/*.patch | sort); do
        echo "applying $(basename "$p")  sha256=$(sha256sum "$p" | awk '{print $1}')"
        git apply "$p"
    done
done

cp "$OFFICIAL_CONFIG" .config
make ARCH=arm64 CROSS_COMPILE="$CROSS" olddefconfig
# The 18.4 configuration is already final, so olddefconfig should change only the compiler
# text lines (CONFIG_CC_VERSION_TEXT and similar). Any other difference is printed and stops
# the script: it means this tree or toolchain does not match the published build.
if ! diff <(grep -v '^#' "$OFFICIAL_CONFIG" | grep -v -E '^CONFIG_(CC_VERSION_TEXT|GCC_VERSION|CC_IS_GCC)=' | sort) \
          <(grep -v '^#' .config           | grep -v -E '^CONFIG_(CC_VERSION_TEXT|GCC_VERSION|CC_IS_GCC)=' | sort); then
    echo "ERROR: olddefconfig changed the 18.4 configuration (differences above)" >&2
    exit 1
fi
rel="$(make -s ARCH=arm64 CROSS_COMPILE="$CROSS" kernelrelease)"
[ "$rel" = "6.18.58-haos" ] || { echo "ERROR: kernelrelease is '$rel', expected 6.18.58-haos" >&2; exit 1; }

# Full build with the one toolchain (vmlinux and all modules), which produces Module.symvers.
make -j"$JOBS" ARCH=arm64 CROSS_COMPILE="$CROSS" vmlinux modules
[ -s Module.symvers ] || { echo "ERROR: Module.symvers not produced" >&2; exit 1; }

echo "tree ready: $KERNEL_TREE  (kernelrelease $rel)"
echo "config sha256: $(sha256sum .config | awk '{print $1}')"
echo "Module.symvers sha256: $(sha256sum Module.symvers | awk '{print $1}')"

# Optional fidelity check, not a gate: the published host modules (as published on the GitHub
# release; signature chain not verified) carry a GNU build-id computed before signing: cfg80211
# 834e2f76f0eac52d7b86865b3395d8b80de77a1d, mac80211 488f6476e6cc4b0e6923e1cbbe73d98062c583f4,
# libarc4 5442ed198511acfe5f406a44bbdce6056c32cb29. In the run of 2026-10-28 the in-tree modules
# built here had different build-ids (cfg80211 bee86120c63b7f6b0f2f0b7b874256ada981c0ff,
# mac80211 3bbbb207cf4d221d398ee478db07a055bf25c048, libarc4
# 7d420f4f9821c4548f39eea3f2feb8e5bff2fe6c), so this tree is not byte-identical to the
# published build; the toolchain commit differs (see above).
for m in net/wireless/cfg80211 net/mac80211/mac80211 lib/crypto/libarc4; do
    printf '%s build-id: ' "$m"
    "${CROSS}readelf" -n "$KERNEL_TREE/$m.ko" 2>/dev/null | awk '/Build ID/ {print $3}'
done
