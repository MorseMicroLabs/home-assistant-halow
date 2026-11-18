#!/usr/bin/env bash
# in-image layout check, run with the image's own bash, BusyBox, apk
# and python3 (entrypoint overridden; nothing is started):
#   - the services are `manager` and `status` (no old `halow` service), with executable
#     run/finish scripts that the image's bash parses;
#   - every library the manager's own source list names (libs.sh) is present, parses, and
#     the real halow_source_all_libs sources the whole set;
#   - the status launcher and server are present;
#   - the external programs the code runs exist;
#   - the pinned packages are installed at exactly the pinned versions (python3 included);
#   - the unprivileged status user exists with its fixed ids, no shell and no home;
#   - no setuid/setgid file and no file capability anywhere in the image;
#   - the udev rule library is gone and nothing sources it.
# Invoked by tests/verify_image.sh as:
#   docker run --rm --entrypoint /bin/bash <image> <this file> "<pins>" <uid> <gid>
set -eu
set -o pipefail

PINS="${1:?pinned packages}" WANT_UID="${2:?uid}" WANT_GID="${3:?gid}"
fails=0
check() { # check <description> <command...>
    local d="$1"; shift
    if "$@"; then echo "  ok: $d"; else echo "  FAIL: $d"; fails=$((fails + 1)); fi
}

echo "-- services --"
check "there is no old 'halow' service" test ! -e /etc/services.d/halow
services="$(cd /etc/services.d && ls -1 | sort | tr '\n' ' ')"
check "the services are exactly manager and status ($services)" test "$services" = "manager status "
for f in /etc/services.d/manager/run /etc/services.d/manager/finish /etc/services.d/status/run; do
    check "$f exists and is executable" test -x "$f"
    check "$f parses with the image's bash" bash -n "$f"
done
if [ -e /etc/services.d/status/finish ]; then
    check "/etc/services.d/status/finish is executable and parses" bash -c 'test -x "$0" && bash -n "$0"' /etc/services.d/status/finish
fi
cinit="$(cd /etc/cont-init.d 2>/dev/null && ls -1A | tr '\n' ' ')"
check "the only cont-init script is the container-environment hardening ($cinit)" test "$cinit" = "00-restrict-container-environment "
check "it is 755 root and parses with the image's bash" bash -c '[ "$(stat -c "%a %U" "$0")" = "755 root" ] && bash -n "$0"' /etc/cont-init.d/00-restrict-container-environment
check "/etc/cont-init.d is 755 root" test "$(stat -c '%a %U' /etc/cont-init.d)" = "755 root"
check "the manager's run uses the shared library list" grep -q 'halow_source_all_libs' /etc/services.d/manager/run
check "the manager's finish uses the shared library list" grep -q 'halow_source_all_libs' /etc/services.d/manager/finish

echo "-- libraries (derived from the manager's own source list) --"
check "libs.sh is present" test -f /usr/lib/halow/libs.sh
# shellcheck source=/dev/null
. /usr/lib/halow/libs.sh
check "the required library list is not empty" test -n "${HALOW_LIBS_REQUIRED:-}"
for lib in $HALOW_LIBS_REQUIRED; do
    check "library $lib.sh is present and parses" bash -n "/usr/lib/halow/${lib}.sh"
done
for f in /usr/lib/halow/*.sh /usr/lib/halow/status/*.sh; do
    check "$(basename "$f") parses" bash -n "$f"
done
if (set +eu; halow_source_all_libs /usr/lib/halow) >/tmp/_halow_src.log 2>&1; then src=0; else src=$?; fi
check "halow_source_all_libs sources every required library in the image (rc $src)" test "$src" -eq 0

echo "-- status service files --"
for f in /usr/lib/halow/status/launcher.sh /usr/lib/halow/status/status_server.py \
         /usr/lib/halow/status/page.html /usr/lib/halow/status/page.css /usr/lib/halow/status/page.js; do
    check "$f is present and world-readable" bash -c 'test -f "$0" && [ "$(stat -c %A "$0" | cut -c8)" = r ]' "$f"
done
check "the status service's run script calls the launcher" grep -q 'halow_status_launcher_main' /etc/services.d/status/run
check "the data tables are present" bash -c 'test -f /usr/share/halow/radio_profiles.psv && test -f /usr/share/halow/guard_manifest.psv'

echo "-- programs the code runs --"
for b in bash ip bridge ss iptables ip6tables iptables-restore ip6tables-restore nft dnsmasq modprobe insmod rmmod lsmod modinfo dbus-send python3 s6-setuidgid curl sysctl mount; do
    check "$b is on PATH ($(command -v "$b" || echo missing))" bash -c 'command -v "$0" >/dev/null' "$b"
done
for b in hostapd_s1g hostapd_cli_s1g; do
    check "/opt/halow/artifacts/$b is executable" test -x "/opt/halow/artifacts/$b"
done
check "the removed helper program is not in the image's artifacts directory" bash -c '! test -e /opt/halow/artifacts/morse_cli'
check "the removed helper program is not anywhere on the image's PATH" bash -c '! command -v morse_cli >/dev/null'

echo "-- pinned package versions --"
for pin in $PINS; do
    name="${pin%%=*}" ver="${pin#*=}"
    got="$(apk info -e -v "$name" 2>/dev/null || true)"
    check "$name is installed at exactly $ver (found: ${got:-none})" test "$got" = "${name}-${ver}"
done
nft_pin="$(for pin in $PINS; do case "$pin" in nftables=*) echo "${pin#nftables=}" ;; esac; done)"
nft_out="$(nft --version 2>&1 || true)"
nft_word="$(awk '{print $1 " " $2}' <<< "$nft_out")"
if [[ "$nft_out" == *"Protocol not supported"* ]]; then
    # nft opens a netfilter netlink socket even for --version. Under user-mode emulation (an
    # x86-64 machine running this aarch64 image through qemu) that socket does not exist, so
    # the program cannot run there; on an aarch64 kernel it prints the version line. Here the
    # version is established from the package database (checked above) and from the version
    # string compiled into the program itself; the run itself is NOT proven by this branch.
    echo "  NOTE: nft --version could not run here (netfilter netlink unavailable under emulation): $nft_out"
    check "nft is an executable file whose compiled-in version string is the pinned ${nft_pin%-r*} (not executed here: emulated kernel)" bash -c 'test -x /usr/sbin/nft && grep -aq -- "$0" /usr/sbin/nft && grep -aq -- "$0" /usr/lib/libnftables.so.1' "${nft_pin%-r*}"
else
    check "nft exists, runs, and its version matches the pin (pin ${nft_pin:-missing}; nft --version: $nft_out)" test -n "$nft_pin" -a "$nft_word" = "nftables v${nft_pin%-r*}"
fi
check "nft is /usr/sbin/nft (the one path the AppArmor profile allows)" test "$(command -v nft)" = /usr/sbin/nft
check "no install log with build-time timestamps is left in the image" test ! -e /var/log/apk.log
check "no build-time random machine id is baked into the image" bash -c 'test ! -e /etc/machine-id && test ! -e /var/lib/dbus/machine-id'
pyver="$(python3 -c 'import platform; print(platform.python_version())')"
check "python3 reports 3.12.16 ($pyver)" test "$pyver" = "3.12.16"

echo "-- the unprivileged status user --"
check "user halowstatus exists" id halowstatus
check "its uid is $WANT_UID" test "$(id -u halowstatus)" = "$WANT_UID"
check "its gid is $WANT_GID" test "$(id -g halowstatus)" = "$WANT_GID"
entry="$(grep '^halowstatus:' /etc/passwd)"
check "its shell is /sbin/nologin ($entry)" test "$(printf '%s' "$entry" | cut -d: -f7)" = "/sbin/nologin"
home="$(printf '%s' "$entry" | cut -d: -f6)"
check "it has no home of its own (home $home is not owned by it)" bash -c '[ ! -e "$0" ] || [ "$(stat -c %u "$0")" != "$1" ]' "$home" "$WANT_UID"
check "it is in no other group" test "$(id -G halowstatus | tr ' ' '\n' | sort -u | tr -d '\n')" = "$WANT_GID"
shadow="$(grep '^halowstatus:' /etc/shadow || true)"
check "its account is locked with no recorded change date ($shadow)" bash -c '[[ $0 == "halowstatus:!::"* ]]' "$shadow"

echo "-- no setuid/setgid files added, no file capabilities --"
# The base image's s6-overlay carries one setuid helper (s6-overlay-suexec, used by /init
# when a container starts as a non-root user; this one starts as root). It is the only
# setuid file allowed; the build removes the setuid bit the dbus package sets on its
# (unused) bus-activation helper.
suid="$(find / -xdev \( -perm -4000 -o -perm -2000 \) -type f 2>/dev/null | grep -vE '^/package/admin/s6-overlay-helpers-[0-9.]+/command/s6-overlay-suexec$' | tr '\n' ' ' || true)"
check "no setuid or setgid file other than the base image's s6-overlay-suexec (${suid:-none})" test -z "$suid"
check "the dbus activation helper has no setuid bit" bash -c '[ ! -e /usr/libexec/dbus-daemon-launch-helper ] || [ ! -u /usr/libexec/dbus-daemon-launch-helper ]'
caps="$(python3 - <<'PY'
import os
found = []
for root in ("/bin", "/sbin", "/usr/bin", "/usr/sbin", "/usr/local/bin", "/opt/halow/artifacts", "/package", "/command", "/usr/lib"):
    for d, _, files in os.walk(root):
        for f in files:
            p = os.path.join(d, f)
            try:
                if os.path.islink(p):
                    continue
                os.getxattr(p, "security.capability")
                found.append(p)
            except OSError:
                pass
print(" ".join(found))
PY
)"
check "no file capability (${caps:-none})" test -z "$caps"

echo "-- file modes: nothing writable by the unprivileged user --"
# (this script itself is bind-mounted from the build machine and is excluded)
ww="$(find / -xdev -perm -0002 ! -type l ! -perm -1000 ! -path "$0" 2>/dev/null | tr '\n' ' ' || true)"
check "no world-writable file or non-sticky directory anywhere (${ww:-none})" test -z "$ww"
owned="$(find / -xdev -user halowstatus 2>/dev/null | tr '\n' ' ' || true)"
check "the status user owns nothing in the image (${owned:-none})" test -z "$owned"
for d in /etc /usr /usr/lib /usr/share /usr/share/licenses /opt /etc/services.d /usr/lib/halow /usr/share/halow /opt/halow/artifacts /usr/share/licenses/morse_micro_halow_ap /usr/share/licenses/morse_micro_halow_ap/LICENSES /usr/share/licenses/morse_micro_halow_ap/third-party-notices /usr/share/licenses/morse_micro_halow_ap/source-offer; do
    check "$d is 755 root ($(stat -c '%a %U' "$d"))" test "$(stat -c '%a %U' "$d")" = "755 root"
done
check "libraries are 644 root ($(stat -c '%a %U' /usr/lib/halow/manager.sh))" test "$(stat -c '%a %U' /usr/lib/halow/manager.sh)" = "644 root"
for f in LICENSE NOTICE THIRD-PARTY-NOTICES.md SOURCE-OFFER.md LICENSES/Apache-2.0.txt LICENSES/GPL-2.0-only.txt LICENSES/LicenseRef-Morse-Micro-Binary-Distribution-License-Agreement.txt LICENSES/LicenseRef-Morse-Micro-Brand-Assets.txt LICENSES/BSD-3-Clause.txt third-party-notices/hostap.README.txt third-party-notices/jemalloc.COPYING.txt PROVENANCE.md provenance.psv corresponding_source.psv source_disposition.psv source-offer/build-modules.sh source-offer/build-hostapd.sh source-offer/kernel-prep.sh source-assets/ASSETS.psv source-assets/SOURCE-INDEX.md; do
    check "/usr/share/licenses/morse_micro_halow_ap/$f is 644 root and not empty" test "$(stat -c '%a %U' "/usr/share/licenses/morse_micro_halow_ap/$f")" = "644 root" -a -s "/usr/share/licenses/morse_micro_halow_ap/$f"
done
check "the artifact manifest is 644 root" test "$(stat -c '%a %U' /opt/halow/artifacts/MANIFEST.sha256)" = "644 root"
check "kernel modules are 644 root" test "$(stat -c '%a %U' /opt/halow/artifacts/morse.ko)" = "644 root"
check "the service scripts are 755 root" test "$(stat -c '%a %U' /etc/services.d/manager/run)" = "755 root"

echo "-- udev is gone --"
check "udev_rule.sh is not in the image" test ! -e /usr/lib/halow/udev_rule.sh
refs="$(grep -rn 'udev_rule' /usr/lib/halow /etc/services.d 2>/dev/null | grep -vE '^[^:]*:[0-9]+:[[:space:]]*#' || true)"
check "no code line refers to udev_rule (${refs:-none})" test -z "$refs"
check "the image's run directory has no udev rule written by this add-on" test ! -e /run/udev/rules.d/90-halow-nm-unmanaged.rules

rm -f /tmp/_halow_src.log
if [ "$fails" -ne 0 ]; then echo "image_layout_check: $fails FAILED"; exit 1; fi
echo "image_layout_check: all passed"
