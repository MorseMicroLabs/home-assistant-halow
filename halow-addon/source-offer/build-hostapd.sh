#!/usr/bin/env bash
# Rebuilds hostapd_s1g and hostapd_cli_s1g (the two executables of the Morse Micro hostap
# fork bundled in artifacts/) from the pinned sources, with the recorded cross toolchain, a
# freshly built static OpenSSL 3.5.9 and path-neutral, deterministic flags. The two shipped
# files are the stripped results; the unstripped (path-mapped) build products are kept in a
# debug directory. Off-device only; nothing here is run by the add-on.
#
# Inputs (environment):
#   TOOLCHAIN_DIR   required. The host directory of the Buildroot toolchain recorded in
#                   corresponding_source.psv (toolchain-source, toolchain-config): it holds
#                   bin/aarch64-buildroot-linux-gnu-gcc and the sysroot with libnl 3.11.0.
#   HOSTAP_SRC      optional. A checkout of https://github.com/MorseMicro/hostap at tag
#                   mm8108-2.1.0 (commit e7309b438eaec4b82f2db29e8ef7beaca3ca52c6). It is only
#                   read (git archive); the build runs in a copy. If unset, the tag is cloned.
#   OPENSSL_TARBALL optional. openssl-3.5.9.tar.gz (SHA-256 below). If unset it is downloaded
#                   from the OpenSSL release page. The checksum is always verified.
#   WORKDIR         optional. Scratch directory (default: a new temporary directory).
#   OUT_DIR         optional. Where the results go (default: $WORKDIR/out).
#
# Build configuration:
#   - hostapd/defconfig of the tag (it already enables CONFIG_DRIVER_NL80211_MORSE=y,
#     CONFIG_MORSE_5GHZ_MAPPED=y, CONFIG_SAE=y, CONFIG_TLS=openssl, CONFIG_IEEE80211AH=y and
#     CONFIG_IEEE80211AC=y), with CONFIG_DPP, CONFIG_DPP2, CONFIG_DPP3 and CONFIG_OWE off;
#   - static linking against the toolchain sysroot's libnl 3.11.0 and the OpenSSL built here;
#   - -Wno-error=unused-variable: the tag does not build with its own -Werror (unused variable
#     at src/ap/ap_config.c:849 when WPS is off and HS20 is on). It only turns that warning
#     back into a warning;
#   - OpenSSL 3.5.9: ./Configure linux-aarch64 no-shared no-dso no-engine no-tests no-apps
#     no-docs --prefix=/usr/local --openssldir=/usr/local/ssl
#     --cross-compile-prefix=aarch64-buildroot-linux-gnu- (the options of the earlier build,
#     with OpenSSL's own neutral default locations instead of a build-machine path), then
#     make and make install_dev into a staging directory (DESTDIR);
#   - path neutrality: -ffile-prefix-map for the source, toolchain, sysroot and OpenSSL
#     paths (it covers debug and macro paths), -Wl,--build-id=none, SOURCE_DATE_EPOCH fixed to
#     the hostap tag commit time, LC_ALL=C, TZ=UTC, umask 022, deterministic ar (ARFLAGS=Dr);
#   - the release files are stripped with the toolchain's own aarch64-buildroot-linux-gnu-strip.
#     The unstripped files are written to $OUT_DIR/debug/. They still contain build-machine
#     paths from the prebuilt toolchain archives (libgcc and the C start files carry debug
#     information with absolute paths); stripping removes them, so the unstripped files are
#     not for distribution.
#
# What a MATCH shows: that the recorded source commit and tarball, this configuration and the
# toolchain named above give these two executables, independent of the directory the build
# runs in. It does not show that the toolchain itself can be rebuilt (see
# corresponding_source.psv). If MANIFEST.sha256 is in the directory above this script (add-on
# layout) both executables are compared with it; otherwise the hashes are only printed.
set -euo pipefail

HOSTAP_COMMIT="e7309b438eaec4b82f2db29e8ef7beaca3ca52c6"
HOSTAP_URL="https://github.com/MorseMicro/hostap.git"
HOSTAP_TAG="mm8108-2.1.0"
OPENSSL_VERSION="3.5.9"
OPENSSL_SHA256="603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a"
OPENSSL_URL="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz"
# Commit time of the hostap tag commit (git log -1 --format=%ct e7309b43...).
export SOURCE_DATE_EPOCH=1789065369
export LC_ALL=C LANG=C TZ=UTC
umask 022

: "${TOOLCHAIN_DIR:?set TOOLCHAIN_DIR to the Buildroot toolchain host directory}"
TOOLCHAIN_DIR="$(cd "$TOOLCHAIN_DIR" && pwd)"
SYSROOT="$TOOLCHAIN_DIR/aarch64-buildroot-linux-gnu/sysroot"
CROSS=aarch64-buildroot-linux-gnu-
export PATH="$TOOLCHAIN_DIR/bin:$PATH"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$SCRIPT_DIR/../MANIFEST.sha256"

WORKDIR="${WORKDIR:-$(mktemp -d)}"
mkdir -p "$WORKDIR"; WORKDIR="$(cd "$WORKDIR" && pwd)"
OUT_DIR="${OUT_DIR:-$WORKDIR/out}"
mkdir -p "$OUT_DIR/debug"; OUT_DIR="$(cd "$OUT_DIR" && pwd)"
echo "compiler: $(${CROSS}gcc --version | head -n 1)"

# --- sources ---------------------------------------------------------------------------
if [ "${HOSTAP_FROM_ARCHIVE:-0}" = "1" ]; then
    # HOSTAP_SRC is an extraction of hostap-source-2.1.0.tar.gz (top directory hostap-2.1.0, the
    # tree of the pinned commit, no git history); the git checks are skipped.
    : "${HOSTAP_SRC:?set HOSTAP_SRC to the extracted hostap-2.1.0 directory}"
    [ -f "$HOSTAP_SRC/hostapd/defconfig" ] && [ -f "$HOSTAP_SRC/src/utils/morse.c" ] || { echo "ERROR: $HOSTAP_SRC is not a Morse Micro hostap source tree" >&2; exit 1; }
    HOSTAP_SRC="$(cd "$HOSTAP_SRC" && pwd)"
else
    if [ -z "${HOSTAP_SRC:-}" ]; then
        git clone --quiet "$HOSTAP_URL" "$WORKDIR/hostap-clone"
        git -C "$WORKDIR/hostap-clone" checkout --quiet "$HOSTAP_TAG"
        HOSTAP_SRC="$WORKDIR/hostap-clone"
    fi
    actual_commit="$(git -C "$HOSTAP_SRC" rev-parse HEAD)"
    if [ "$actual_commit" != "$HOSTAP_COMMIT" ]; then
        echo "ERROR: HOSTAP_SRC is at $actual_commit, not $HOSTAP_COMMIT" >&2; exit 1
    fi
    if [ -n "$(git -C "$HOSTAP_SRC" status --porcelain)" ]; then
        echo "ERROR: HOSTAP_SRC has uncommitted or untracked changes; use a clean checkout" >&2; exit 1
    fi
fi
if [ -z "${OPENSSL_TARBALL:-}" ]; then
    OPENSSL_TARBALL="$WORKDIR/openssl-${OPENSSL_VERSION}.tar.gz"
    [ -f "$OPENSSL_TARBALL" ] || curl -fsSL -o "$OPENSSL_TARBALL" "$OPENSSL_URL"
fi
got="$(sha256sum "$OPENSSL_TARBALL" | awk '{print $1}')"
if [ "$got" != "$OPENSSL_SHA256" ]; then
    echo "ERROR: OpenSSL tarball checksum $got, expected $OPENSSL_SHA256" >&2; exit 1
fi

# --- OpenSSL (static, neutral prefix, staged) --------------------------------------------
OSSL_SRC="$WORKDIR/src/openssl-${OPENSSL_VERSION}"
OSSL_STAGE="$WORKDIR/openssl-stage"
rm -rf "$WORKDIR/src" "$OSSL_STAGE"; mkdir -p "$WORKDIR/src" "$OSSL_STAGE"
tar -xzf "$OPENSSL_TARBALL" -C "$WORKDIR/src"
( cd "$OSSL_SRC"
  ./Configure linux-aarch64 no-shared no-dso no-engine no-tests no-apps no-docs \
      --prefix=/usr/local --openssldir=/usr/local/ssl --cross-compile-prefix="$CROSS" \
      "-ffile-prefix-map=$OSSL_SRC=/build/openssl" "-ffile-prefix-map=$TOOLCHAIN_DIR=/toolchain" \
      "-ffile-prefix-map=$SYSROOT=/sysroot" ARFLAGS=Dr >/dev/null
  make -j"$(nproc)" >/dev/null
  make DESTDIR="$OSSL_STAGE" install_dev >/dev/null )

# --- hostap ------------------------------------------------------------------------------
BUILD="$WORKDIR/src/hostap"
rm -rf "$BUILD"; mkdir -p "$BUILD"
if [ "${HOSTAP_FROM_ARCHIVE:-0}" = "1" ]; then
    cp -a "$HOSTAP_SRC/." "$BUILD/"
else
    git -C "$HOSTAP_SRC" archive --format=tar HEAD | tar -x -C "$BUILD"
fi
OSSL_ROOT="$OSSL_STAGE/usr/local"
cd "$BUILD/hostapd"
cp defconfig .config
sed -i -E 's/^CONFIG_(DPP|DPP2|DPP3|OWE)=y/#CONFIG_\1=y/' .config
cat >> .config <<CFG
CFLAGS += -I$SYSROOT/usr/include/libnl3 -I$OSSL_ROOT/include -Wno-error=unused-variable -ffile-prefix-map=$TOOLCHAIN_DIR=/toolchain -ffile-prefix-map=$SYSROOT=/sysroot -ffile-prefix-map=$OSSL_STAGE=/openssl-stage -ffile-prefix-map=$BUILD=/build/hostap
LDFLAGS += -static -L$SYSROOT/usr/lib -L$OSSL_ROOT/lib -Wl,--build-id=none
CFG
make CC="${CROSS}gcc" AR="${CROSS}ar" -j"$(nproc)" >/dev/null

for f in hostapd_s1g hostapd_cli_s1g; do
    cp "$f" "$OUT_DIR/debug/$f"
    "${CROSS}strip" -o "$OUT_DIR/$f" "$f"
done
cp .config "$OUT_DIR/debug/hostapd.config"

status=0
for f in hostapd_s1g hostapd_cli_s1g; do
    built="$(sha256sum "$OUT_DIR/$f" | awk '{print $1}')"
    dbg="$(sha256sum "$OUT_DIR/debug/$f" | awk '{print $1}')"
    echo "$f: stripped sha256 $built (unstripped $dbg)"
    if [ -f "$MANIFEST" ]; then
        recorded="$(awk -v p="./$f" '$2 == p { print $1; exit }' "$MANIFEST")"
        if [ "$built" = "$recorded" ]; then echo "$f: MATCH MANIFEST.sha256"
        else echo "$f: DIFFERS from MANIFEST.sha256 ($recorded)"; status=1; fi
    fi
done
echo "results in $OUT_DIR"
exit "$status"
