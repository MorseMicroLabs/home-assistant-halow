#!/usr/bin/env bash
# Helpers for test_guard.sh and test_adapter.sh: a minimal hermetic setup that sources only the
# libraries under test, a fake USB sysfs tree laid out like the real one (entries under
# bus/usb/devices are symlinks into a devices/ hierarchy), and a restricted command directory
# that records every external command run.

# hat_setup: temp dir, constants, logging and the two libraries under test.
hat_setup() {
    HAT_TMP="$(mktemp -d)"
    HALOW_TEST_TMP="$HAT_TMP"
    HAT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../rootfs/usr/lib/halow" && pwd)"
    HAT_SHARE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../rootfs/usr/share/halow" && pwd)"
    export HALOW_SYS_MODULE_DIR="$HAT_TMP/sys/module"
    export HALOW_ARTIFACTS_DIR="$HAT_TMP/artifacts"
    export HALOW_GUARD_MANIFEST="$HAT_TMP/guard_manifest.psv"
    export HALOW_GUARD_TEST_MODE=1
    export HALOW_SYS_USB_DIR="$HAT_TMP/sys/bus/usb/devices"
    unset HALOW_UNAME_RELEASE
    mkdir -p "$HALOW_SYS_MODULE_DIR" "$HALOW_ARTIFACTS_DIR" "$HALOW_SYS_USB_DIR" \
             "$HAT_TMP/sys/devices/platform/xhci-hcd.0/usb1" "$HAT_TMP/bin"
    HAT_CALLS="$HAT_TMP/calls.log"
    : > "$HAT_CALLS"
    export HAT_CALLS
    # shellcheck source=/dev/null
    . "$HAT_LIB_DIR/constants.sh"
    # shellcheck source=/dev/null
    . "$HAT_LIB_DIR/common.sh"
    # shellcheck source=/dev/null
    . "$HAT_LIB_DIR/guard.sh"
    # shellcheck source=/dev/null
    . "$HAT_LIB_DIR/adapter.sh"
}

hat_teardown() {
    [ -n "${HAT_TMP:-}" ] && rm -rf -- "$HAT_TMP"
}

# ---- fake USB tree ----------------------------------------------------------------------------

# hat_usb_add <busid> <vendor> <product> [<busnum> <devnum>]
# Creates the physical device directory and the bus/usb/devices/<busid> symlink to it, plus an
# interface entry "<busid>:1.0" (a symlink without idVendor, as in real sysfs).
hat_usb_add() {
    local id="$1" v="$2" p="$3" bn="${4:-1}" dn="${5:-2}" phys
    phys="$HAT_TMP/sys/devices/platform/xhci-hcd.0/usb1/$id"
    mkdir -p "$phys/$id:1.0"
    printf '%s\n' "$v" > "$phys/idVendor"
    printf '%s\n' "$p" > "$phys/idProduct"
    printf '%s\n' "$bn" > "$phys/busnum"
    printf '%s\n' "$dn" > "$phys/devnum"
    ln -s "../../../devices/platform/xhci-hcd.0/usb1/$id" "$HALOW_SYS_USB_DIR/$id"
    ln -s "../../../devices/platform/xhci-hcd.0/usb1/$id/$id:1.0" "$HALOW_SYS_USB_DIR/$id:1.0"
}

# hat_usb_add_netdev <busid> <ifname>: the interface several levels below the device.
hat_usb_add_netdev() {
    mkdir -p "$HAT_TMP/sys/devices/platform/xhci-hcd.0/usb1/$1/$1:1.0/host0/wiphy-glue/net/$2/queues"
}

hat_usb_remove() {
    rm -rf -- "$HAT_TMP/sys/devices/platform/xhci-hcd.0/usb1/$1"
    rm -f -- "$HALOW_SYS_USB_DIR/$1" "$HALOW_SYS_USB_DIR/$1:1.0"
}

hat_usb_phys() { printf '%s' "$HAT_TMP/sys/devices/platform/xhci-hcd.0/usb1/$1"; }

# ---- command recording ------------------------------------------------------------------------

# hat_recording_bin <dir> <passthrough command...>
# Fills <dir> with wrappers: each named pass-through command logs "<name> <args>" to HAT_CALLS
# and runs the real binary; a set of state-changing commands logs "MUTATE <name>" and fails.
# Put <dir> alone on PATH to record every external command a function runs.
hat_recording_bin() {
    local dir="$1" c real; shift
    mkdir -p "$dir"
    for c in "$@"; do
        if [ -e "$dir/$c" ]; then continue; fi
        real="$(command -v "$c")"
        printf '#!%s\nprintf "%%s %%s\\n" "%s" "$*" >> "$HAT_CALLS"\nexec "%s" "$@"\n' \
            "$BASH" "$c" "$real" > "$dir/$c"
        chmod +x "$dir/$c"
    done
    for c in insmod rmmod modprobe depmod mkdir rm rmdir mv cp ln touch chmod chown tee dd sed \
             ip iptables ip6tables bridge nmcli busctl dbus-send mount umount sysctl kill sh bash \
             cat tr grep awk readlink sleep; do
        if [ -e "$dir/$c" ]; then continue; fi
        printf '#!%s\nprintf "MUTATE-OR-UNEXPECTED %%s %%s\\n" "%s" "$*" >> "$HAT_CALLS"\nexit 1\n' \
            "$BASH" "$c" > "$dir/$c"
        chmod +x "$dir/$c"
    done
}

# hat_called_commands: prints the distinct command names recorded, space separated, sorted.
hat_called_commands() {
    local line name seen=" "
    while IFS= read -r line; do
        name="${line%% *}"
        case "$seen" in *" $name "*) continue ;; esac
        seen="${seen}${name} "
    done < "$HAT_CALLS"
    printf '%s' "$seen"
}

# ---- fake kernel for the compatibility guard ---------------------------------------------------
#
# hat_guard_world <dir> [<artifacts dir>]
# Builds a complete supported fake host under <dir> and exports the guard's path variables:
#   <dir>/base/lib/modules/<rel>/kernel/...   cfg80211.ko, mac80211.ko, libarc4.ko (small files)
#   <dir>/proc_version, <dir>/config.gz      the running kernel's banner and configuration
#   <dir>/guard_manifest.psv                 a manifest with the files' real SHA-256 values
#   <artifacts dir>/morse.ko, dot11ah.ko     bundled modules (default $HALOW_ARTIFACTS_DIR)
#   <dir>/bin/modinfo, <dir>/bin/uname       fakes; put <dir>/bin first on PATH
#   $HALOW_SYS_MODULE_DIR/firmware_class     so the loaded-module directory is not empty
# and exports HALOW_GUARD_TEST_MODE=1 (the guard ignores its overrides without it).
# The fake modinfo reads "<field>=<value>" lines from a module file (decompressing .xz/.gz, and
# failing on .zst or on a file containing UNREADABLE), and resolves "-b <base> -k <rel> -F
# filename <module>" like the module loader: the first <module>.ko* found under updates/, then
# extra/, then kernel/, unless <rel>/fake.resolve has a "<module> <relative path>" line. The fake
# uname answers -r with $HAT_GW_RELEASE and -v with $HAT_GW_BUILD (fails with
# HAT_GW_UNAME_FAIL=r|v). Calls are logged to $HAT_CALLS when it is set.
# Variables set: HAT_GW_REL HAT_GW_VM HAT_GW_BUILD HAT_GW_BANNER HAT_GW_CONFIG_SHA HAT_GW_BIN
#                HAT_GW_TREE (the release's module directory) HAT_GW_BID_<module>.
hat_guard_world() {
    local dir="$1" art="${2:-$HALOW_ARTIFACTS_DIR}" m rel_path f find_bin xz_bin gzip_bin sort_bin
    HAT_GW_REL="6.18.58-haos"
    HAT_GW_VM="6.18.58-haos SMP preempt mod_unload aarch64"
    HAT_GW_BUILD="#1 SMP PREEMPT Tue Oct 27 13:46:33 UTC 2026"
    HAT_GW_BANNER="Linux version 6.18.58-haos (builder@fakehost) (test toolchain) $HAT_GW_BUILD"
    export HAT_GW_REL HAT_GW_VM HAT_GW_BUILD
    # the guard honours its path overrides only in test mode
    export HALOW_GUARD_TEST_MODE=1
    # a real loaded-module directory always lists other modules; the guard refuses an empty one
    if [ -n "${HALOW_SYS_MODULE_DIR:-}" ]; then mkdir -p "$HALOW_SYS_MODULE_DIR/firmware_class"; fi
    export HALOW_MODULES_BASE="$dir/base"
    export HALOW_PROC_VERSION="$dir/proc_version"
    export HALOW_PROC_CONFIG_GZ="$dir/config.gz"
    export HALOW_GUARD_MANIFEST="$dir/guard_manifest.psv"
    HAT_GW_TREE="$HALOW_MODULES_BASE/lib/modules/$HAT_GW_REL"
    HAT_GW_BIN="$dir/bin"
    HAT_GW_BID_cfg80211="99a5f3f4b4c9443414b0b28e7d707d269fa086e0"
    HAT_GW_BID_mac80211="1de0662243787d60d5259a921cbe544a1c819d44"
    HAT_GW_BID_libarc4="94863da8368a0640eb7cfaab17dac9128bee1d75"
    mkdir -p "$HAT_GW_TREE" "$HAT_GW_BIN" "$art"
    printf '%s\n' "$HAT_GW_BANNER" > "$HALOW_PROC_VERSION"
    printf 'CONFIG_TEST=y\nCONFIG_MODULE_SIG=y\n' | gzip -c > "$HALOW_PROC_CONFIG_GZ"
    HAT_GW_CONFIG_SHA="$(printf 'CONFIG_TEST=y\nCONFIG_MODULE_SIG=y\n' | sha256sum)"; HAT_GW_CONFIG_SHA="${HAT_GW_CONFIG_SHA%% *}"
    printf 'srcversion=33333333333333333333333\nvermagic=%s\n' "$HAT_GW_VM" > "$art/morse.ko"
    printf 'srcversion=44444444444444444444444\nvermagic=%s\n' "$HAT_GW_VM" > "$art/dot11ah.ko"
    {
        echo "# test manifest"
        echo "release|$HAT_GW_REL|vermagic|$HAT_GW_VM"
        echo "kernel_build|$HAT_GW_REL|uname_v|$HAT_GW_BUILD"
        echo "kernel_banner|$HAT_GW_REL|$HAT_GW_BANNER"
        echo "kernel_config|$HAT_GW_REL|$HAT_GW_CONFIG_SHA"
        for m in cfg80211 mac80211 libarc4; do
            case "$m" in
                cfg80211) rel_path="kernel/net/wireless/cfg80211.ko" ;;
                mac80211) rel_path="kernel/net/mac80211/mac80211.ko" ;;
                libarc4)  rel_path="kernel/lib/crypto/libarc4.ko" ;;
            esac
            f="$HAT_GW_TREE/$rel_path"
            mkdir -p "$(dirname "$f")"
            printf 'vermagic=%s\nname=%s\nbody=official %s module bytes\n' "$HAT_GW_VM" "$m" "$m" > "$f"
            local bidvar="HAT_GW_BID_$m" sum
            sum="$(sha256sum "$f")"
            echo "host_module|$HAT_GW_REL|$m|$rel_path|${sum%% *}|${!bidvar}"
        done
        echo "artifact|$HAT_GW_REL|morse.ko|33333333333333333333333"
        echo "artifact|$HAT_GW_REL|dot11ah.ko|44444444444444444444444"
    } > "$HALOW_GUARD_MANIFEST"
    find_bin="$(command -v find)"; xz_bin="$(command -v xz)"; gzip_bin="$(command -v gzip)"; sort_bin="$(command -v sort)"
    cat > "$HAT_GW_BIN/modinfo" <<EOF
#!$BASH
[ -n "\${HAT_CALLS:-}" ] && printf 'modinfo %s\n' "\$*" >> "\$HAT_CALLS"
field=""; file=""; base=""; kver=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        -F) field="\$2"; shift 2 ;;
        -b) base="\$2"; shift 2 ;;
        -k) kver="\$2"; shift 2 ;;
        *) file="\$1"; shift ;;
    esac
done
if [ -n "\$base" ]; then
    root="\${base%/}/lib/modules/\$kver"
    [ -d "\$root" ] || exit 1
    if [ -f "\$root/fake.resolve" ]; then
        while read -r mm pp; do
            if [ "\$mm" = "\$file" ]; then printf '%s\n' "\$root/\$pp"; exit 0; fi
        done < "\$root/fake.resolve"
    fi
    for sub in updates extra kernel; do
        [ -d "\$root/\$sub" ] || continue
        hit=""
        while IFS= read -r p; do [ -z "\$hit" ] && hit="\$p"; done < <("$find_bin" "\$root/\$sub" -name "\$file.ko*" | "$sort_bin")
        if [ -n "\$hit" ]; then printf '%s\n' "\$hit"; exit 0; fi
    done
    exit 1
fi
[ -f "\$file" ] && [ -r "\$file" ] || exit 1
case "\$file" in
    *.zst) exit 1 ;;
    *.xz) content="\$("$xz_bin" -dc "\$file" 2>/dev/null)" || exit 1 ;;
    *.gz) content="\$("$gzip_bin" -dc "\$file" 2>/dev/null)" || exit 1 ;;
    *) content="\$(<"\$file")" ;;
esac
case "\$content" in *UNREADABLE*) exit 1 ;; esac
while IFS= read -r l; do
    case "\$l" in "\$field="*) printf '%s\n' "\${l#*=}" ;; esac
done <<< "\$content"
exit 0
EOF
    cat > "$HAT_GW_BIN/uname" <<EOF
#!$BASH
[ -n "\${HAT_CALLS:-}" ] && printf 'uname %s\n' "\$*" >> "\$HAT_CALLS"
case "\$1" in
    -r) [ "\${HAT_GW_UNAME_FAIL:-}" = r ] && exit 1; printf '%s\n' "\${HAT_GW_RELEASE-\$HAT_GW_REL}" ;;
    -v) [ "\${HAT_GW_UNAME_FAIL:-}" = v ] && exit 1; printf '%s\n' "\${HAT_GW_BUILD_SEEN-\$HAT_GW_BUILD}" ;;
    *) exit 1 ;;
esac
EOF
    chmod +x "$HAT_GW_BIN/modinfo" "$HAT_GW_BIN/uname"
}

# hat_gw_note <file> <40-hex build-id>: writes a raw GNU build-id ELF note as sysfs exposes it.
hat_gw_note() {
    local hex="$2" i out='\x04\x00\x00\x00\x14\x00\x00\x00\x03\x00\x00\x00GNU\x00'
    for ((i = 0; i < 40; i += 2)); do out="${out}\\x${hex:$i:2}"; done
    mkdir -p "$(dirname "$1")"
    printf '%b' "$out" > "$1"
}

# hat_tree_listing <dir>: a listing of every path with its type, size and mtime (for "nothing
# changed" assertions).
hat_tree_listing() {
    find "$1" -printf '%p %y %s %T@\n' | LC_ALL=C sort
}
