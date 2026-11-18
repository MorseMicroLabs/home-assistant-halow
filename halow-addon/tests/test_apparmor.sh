#!/usr/bin/env bash
# Static checks of apparmor.txt. These prove only that the profile is well formed and
# covers what the code in rootfs/ does on paper; they do NOT prove that it loads or
# confines correctly on the target device (that needs a complain-mode run there).
#
#   - one top-level profile, named exactly as the add-on slug, with the required flags,
#     never in complain mode;
#   - nothing broader than needed: no blanket file/capability/network/mount rule, no
#     /** rule, no unconfined execution, no change_profile, no dangerous capability;
#   - the required capabilities, the /sys bind remount and the firmware search path write;
#   - every external program the code runs (found by scanning rootfs/ for command-position
#     uses of the programs the image carries) is in this test's catalogue, and every
#     catalogued program's real path in the image is executable under the profile;
#   - the file accesses the code performs are permitted, and a set of host paths is not;
#   - the status server runs in a child profile with no capabilities and read-only files;
#   - syntax, with apparmor_parser when it is installed (skipped with a note otherwise).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh

echo "== test_apparmor =="

PROFILE="../apparmor.txt"
CONFIG="../config.yaml"
ROOTFS="../rootfs"
assert_file_exists "$PROFILE" "apparmor.txt exists"

# Rule lines without comments.
RULES="$(sed -E 's/^[[:space:]]*#.*$//; s/[[:space:]]+#.*$//' "$PROFILE" | grep -v '^[[:space:]]*$')"
# Keep '#include' lines (they look like comments).
INCLUDES="$(grep -E '^[[:space:]]*#include' "$PROFILE")"

slug="$(awk '/^slug:/ { sub(/^slug:[[:space:]]*/, ""); gsub(/"/, ""); print; exit }' "$CONFIG")"

echo "-- structure --"
assert_success "the profile includes the global tunables" grep -qx '#include <tunables/global>' <<< "$INCLUDES"
assert_success "the profile includes the base abstraction" grep -qE '^[[:space:]]+#include <abstractions/base>$' <<< "$INCLUDES"
top_profiles="$(grep -cE '^profile[[:space:]]' <<< "$RULES")"
assert_eq "1" "$top_profiles" "there is exactly one top-level profile"
top_line="$(grep -E '^profile[[:space:]]' <<< "$RULES")"
assert_eq "profile $slug flags=(attach_disconnected,mediate_deleted) {" "$top_line" "the top-level profile is named exactly as the slug ($slug) with the required flags"
assert_failure "no rule or flag puts the profile in complain mode" grep -qiE 'complain' <<< "$RULES"
assert_failure "no profile uses the kill or unconfined mode flags" grep -qE 'flags=\([^)]*(kill|unconfined|prompt)' <<< "$RULES"
assert_success "the header records the enforce-mode evidence and its limits" grep -q "in enforce mode on" "$PROFILE"
assert_success "the header says it must be re-confirmed after every software update" \
    grep -qi "re-confirmed on a real device after every software update" "$PROFILE"
opens="$(tr -cd '{' <<< "$(sed -E 's/\{[^{}]*,[^{}]*\}//g; s/\{,\*\*\}//g' <<< "$RULES")" | wc -c)"
closes="$(tr -cd '}' <<< "$(sed -E 's/\{[^{}]*,[^{}]*\}//g; s/\{,\*\*\}//g' <<< "$RULES")" | wc -c)"
assert_eq "$opens" "$closes" "profile braces balance"

echo "-- nothing broader than needed --"
assert_failure "no blanket 'file,' rule" grep -qE '^[[:space:]]*(allow[[:space:]]+)?file[[:space:]]*,' <<< "$RULES"
assert_failure "no blanket 'capability,' rule" grep -qE '^[[:space:]]*capability[[:space:]]*,' <<< "$RULES"
assert_failure "no blanket 'network,' rule" grep -qE '^[[:space:]]*network[[:space:]]*,' <<< "$RULES"
assert_failure "no blanket 'mount,' or 'remount,' rule" grep -qE '^[[:space:]]*(mount|remount)[[:space:]]*,' <<< "$RULES"
assert_failure "no 'dbus,' blanket rule" grep -qE '^[[:space:]]*dbus[[:space:]]*,' <<< "$RULES"
assert_failure "no rule on the whole file system (/** or /{,**} or /*)" grep -qE '^[[:space:]]*(owner[[:space:]]+)?/(\*\*|\{,\*\*\}|\*)[[:space:]]' <<< "$RULES"
assert_failure "no unconfined or profile-less execution (ux, Ux, pux, PUx, cux)" grep -qE '[[:space:]][pPcC]?[uU]x[[:space:]]*(->|,)' <<< "$RULES"
assert_failure "no change_profile or change_hat" grep -qE '^[[:space:]]*(change_profile|\^)' <<< "$RULES"
assert_failure "no ptrace trace permission (read only)" grep -qE 'ptrace[[:space:]]*\(?[^)]*trace' <<< "$RULES"
for cap in sys_ptrace sys_rawio sys_boot mac_admin mac_override sys_time mknod bpf perfmon audit_control linux_immutable sys_chroot sys_pacct setpcap ipc_owner wake_alarm block_suspend; do
    assert_failure "capability $cap is not granted" grep -qE "^[[:space:]]*capability[[:space:]]+([a-z_]+[[:space:]]+)*${cap}[[:space:]]*," <<< "$RULES"
done
TMPFS_RULE='mount fstype=tmpfs options=(rw, nosuid, nodev, noexec, silent) tmpfs -> /run/halow/,'
IPV6_PATH='@{PROC}/sys/net/ipv6/conf/*/disable_ipv6'
IPV6_BIND_RULE="mount options in (bind, rw, silent) $IPV6_PATH -> $IPV6_PATH,"
IPV6_REMOUNT_RULE="remount options in (bind, ro, rw, nosuid, nodev, noexec, relatime, silent) $IPV6_PATH,"
IPV6_UMOUNT_RULE="umount $IPV6_PATH,"
assert_failure "no allow rule for mount, remount or umount other than the /sys remount, the /run/halow tmpfs and the three on the per-interface disable_ipv6 path" bash -c 'grep -E "^[[:space:]]*(mount|remount|umount)[[:space:]]" <<< "$0" | grep -vE "^[[:space:]]*remount[[:space:]].*[[:space:]]/sys/,$" | grep -vxF "  $1" | grep -vxF "  $2" | grep -vxF "  $3" | grep -vxF "  $4"' "$RULES" "$TMPFS_RULE" "$IPV6_BIND_RULE" "$IPV6_REMOUNT_RULE" "$IPV6_UMOUNT_RULE"
assert_eq "2" "$(grep -cE '^[[:space:]]*mount[[:space:]]' <<< "$RULES")" "exactly two allow mount rules (the tmpfs and the IPv6 bracket's bind)"
assert_eq "2" "$(grep -cE '^[[:space:]]*remount[[:space:]]' <<< "$RULES")" "exactly two allow remount rules (/sys and the IPv6 bracket)"
assert_eq "1" "$(grep -cE '^[[:space:]]*umount[[:space:]]' <<< "$RULES")" "exactly one allow umount rule (the IPv6 bracket's temporary mount)"
assert_failure "no blanket 'umount,' allow rule" grep -qE '^[[:space:]]*umount[[:space:]]*,' <<< "$RULES"
assert_failure "no blanket 'deny umount,' (an explicit deny would beat the umount allow; every other umount is denied by default as no rule grants it)" grep -qE '^[[:space:]]*deny umount[[:space:]]*,' <<< "$RULES"
assert_success "pivot_root stays explicitly denied" grep -qE '^[[:space:]]*deny pivot_root,' <<< "$RULES"
echo "-- the IPv6 temporary mount bracket (exact file, three operations, all/default denied) --"
assert_success "the bind mount of a disable_ipv6 file onto itself is the exact rule" grep -qxF "  $IPV6_BIND_RULE" <<< "$RULES"
assert_success "its remount is the exact rule" grep -qxF "  $IPV6_REMOUNT_RULE" <<< "$RULES"
assert_success "its umount is the exact rule" grep -qxF "  $IPV6_UMOUNT_RULE" <<< "$RULES"
assert_failure "none of the three uses a wildcard that crosses directories (no ** and no wildcard in the file name)" grep -E "^[[:space:]]*(mount|remount|umount)[[:space:]].*(\*\*|disable_ipv6\*|\*disable)" <<< "$RULES"
for op in "mount @{PROC}/sys/net/ipv6/conf/{all,default}/disable_ipv6 -> @{PROC}/sys/net/ipv6/conf/{all,default}/disable_ipv6" \
          "mount @{PROC}/sys/net/ipv6/conf/{all,default}/disable_ipv6" "mount -> @{PROC}/sys/net/ipv6/conf/{all,default}/disable_ipv6" \
          "remount @{PROC}/sys/net/ipv6/conf/{all,default}/disable_ipv6" "umount @{PROC}/sys/net/ipv6/conf/{all,default}/disable_ipv6"; do
    assert_success "the host-wide entries are denied explicitly: deny $op" grep -qxF "  deny $op," <<< "$RULES"
done
assert_failure "no mount, remount or umount rule names /proc/sys outside the per-interface disable_ipv6 pattern" bash -c 'grep -E "^[[:space:]]*(deny[[:space:]]+)?(mount|remount|umount)[[:space:]]" <<< "$0" | grep -E "(PROC\}|/proc)" | grep -vE "ipv6/conf/(\*|\{all,default\})/disable_ipv6"' "$RULES"

echo "-- required grants --"
for cap in sys_module sys_admin net_admin net_raw setuid setgid kill; do
    assert_success "capability $cap is granted" grep -qE "^[[:space:]]*capability[[:space:]]+${cap}[[:space:]]*," <<< "$RULES"
done
assert_success "the bind remount of /sys is permitted (bind, ro and rw)" \
    grep -qE '^[[:space:]]*remount options in \([^)]*bind[^)]*\) /sys/,$' <<< "$RULES"
remount_line="$(grep -E '^[[:space:]]*remount .* /sys/,$' <<< "$RULES")"
assert_success "the remount rule allows ro" grep -qE '[(, ]ro[,)]' <<< "$remount_line"
assert_success "the remount rule allows rw" grep -qE '[(, ]rw[,)]' <<< "$remount_line"
assert_failure "the remount rule is not for any other mount point" grep -qvE ' /sys/,$' <<< "$remount_line"
# The flags BusyBox mount really passes (traced under qemu-aarch64 -strace from the image's
# own BusyBox against the container's /sys entry "ro,nosuid,nodev,noexec,relatime"):
#   MS_BIND|MS_NODEV|MS_NOEXEC|MS_NOSUID|MS_RELATIME|MS_REMOUNT|MS_SILENT (+MS_RDONLY)
# Every one must be in the rule's option set, or the remount is denied under enforcement.
remount_opts="$(sed -E 's/.*options in \(([^)]*)\).*/\1/; s/[[:space:]]//g' <<< "$remount_line" | tr ',' '\n' | sort | tr '\n' ' ')"
for flag in bind nodev noexec nosuid relatime silent ro rw; do
    assert_success "the remount rule allows the traced flag '$flag' (options: $remount_opts)" grep -qw -- "$flag" <<< "$remount_opts"
done
for flag in suid dev exec rbind move sync mand; do
    assert_failure "the remount rule does not allow '$flag'" grep -qw -- "$flag" <<< "$remount_opts"
done
echo "-- the memory-backed run directory --"
mount_line="$(grep -E '^[[:space:]]*mount[[:space:]]+fstype=' <<< "$RULES")"
assert_eq "  $TMPFS_RULE" "$mount_line" "the one fstype mount rule is exactly a tmpfs on /run/halow with the traced flags (nosuid, nodev, noexec, silent; not read-only)"
assert_success "the mount rule names the tmpfs type (no other file system can be mounted)" grep -qF 'fstype=tmpfs' <<< "$mount_line"
assert_success "the mount rule uses an exact option set (options=, not options in)" grep -qF 'options=(' <<< "$mount_line"
assert_success "the mount target is /run/halow/ only" grep -qE ' -> /run/halow/,$' <<< "$mount_line"
manager_mount="$(grep -hoE 'mount -t tmpfs -o [^ ]+' ../rootfs/usr/lib/halow/*.sh 2>/dev/null | awk 'NR == 1' || true)"
if [ -n "$manager_mount" ]; then
    mflags="$(sed -E 's/.*-o //; s/["'\'']//g' <<< "$manager_mount" | tr ',' '\n' | grep -vE '=' | sort | tr '\n' ' ')"
    assert_eq "nodev noexec nosuid " "$mflags" "the manager's tmpfs mount flags ($manager_mount) are exactly the ones the rule allows"
else
    echo "  note: no 'mount -t tmpfs -o ...' found in the libraries yet; the code-side flag comparison was SKIPPED"
fi
assert_success "the host firmware search path may be read and written" \
    grep -qE '^[[:space:]]*/sys/module/firmware_class/parameters/path rw,$' <<< "$RULES"
for fam in "netlink raw" "netlink dgram" "packet raw" "packet dgram" "inet stream" "inet dgram" "unix stream" "unix dgram"; do
    assert_success "network $fam is permitted" grep -qE "^[[:space:]]*network ${fam},$" <<< "$RULES"
done
assert_success "the host D-Bus socket may be used" grep -qE '^[[:space:]]*/run/dbus/system_bus_socket rw,$' <<< "$RULES"
assert_success "D-Bus is limited to NetworkManager and the bus itself" grep -qE 'dbus \(send, receive\) bus=system peer=\(name=org.freedesktop.NetworkManager\),' <<< "$RULES"
assert_success "host kernel modules may be read (dependency resolution, compatibility check)" grep -qE '^[[:space:]]*/lib/modules/\*\* r,$' <<< "$RULES"

# --- A small evaluator for the profile's own path rules -------------------------------
# _aa_rx <apparmor glob> — prints an anchored extended regex for it.
_aa_rx() {
    local g="$1" out="" i c n depth=0
    g="${g//@\{PROC\}//proc}"
    for (( i = 0; i < ${#g}; i++ )); do
        c="${g:i:1}"; n="${g:i+1:1}"
        case "$c" in
            '*') if [ "$n" = '*' ]; then out+='.*'; i=$((i + 1)); else out+='[^/]*'; fi ;;
            '?') out+='[^/]' ;;
            '{') out+='('; depth=$((depth + 1)) ;;
            '}') out+=')'; depth=$((depth - 1)) ;;
            ',') if [ "$depth" -gt 0 ]; then out+='|'; else out+=','; fi ;;
            '.'|'+'|'('|')'|'|'|'^'|'$') out+="\\$c" ;;
            '[') out+='[' ;;
            *) out+="$c" ;;
        esac
    done
    printf '^%s$' "$out"
}
# _aa_rules <scope> — prints "path<TAB>perms" for allow rules of the top-level profile
# (scope=top) or of the named child profile.
_aa_rules() {
    awk -v want="$1" '
        /^[[:space:]]*#/ { next }
        { sub(/[[:space:]]+#.*$/, "") }
        /^profile[[:space:]]/ { depth = 1; scope = "top"; next }
        /^[[:space:]]+profile[[:space:]]/ { depth = 2; split($0, w, /[[:space:]]+/); scope = w[3]; next }
        /^[[:space:]]*}[[:space:]]*$/ { depth--; if (depth == 1) scope = "top"; next }
        scope == want && /^[[:space:]]*(owner[[:space:]]+)?(\/|@\{PROC\})[^[:space:]]*[[:space:]]+[a-zA-Z]+([[:space:]]*->[[:space:]]*[^[:space:],]+)?,[[:space:]]*$/ {
            line = $0; sub(/^[[:space:]]*(owner[[:space:]]+)?/, "", line); sub(/,[[:space:]]*$/, "", line)
            split(line, p, /[[:space:]]+/); print p[1] "\t" p[2]
        }' "$PROFILE"
}
_aa_denies() {
    awk -v want="$1" '
        /^profile[[:space:]]/ { scope = "top"; next }
        /^[[:space:]]+profile[[:space:]]/ { split($0, w, /[[:space:]]+/); scope = w[3]; next }
        /^[[:space:]]*}[[:space:]]*$/ { scope = "top"; next }
        scope == want && /^[[:space:]]*deny[[:space:]]+(\/|@\{PROC\})/ { line = $0; sub(/^[[:space:]]*deny[[:space:]]+/, "", line); sub(/,[[:space:]]*$/, "", line); split(line, p, /[[:space:]]+/); print p[1] "\t" p[2] }' "$PROFILE"
}
TOP_RULES="$(_aa_rules top)"
CHILD_RULES="$(_aa_rules halow_status)"
CHILD_DENIES="$(_aa_denies halow_status)"
# _aa_allows <rules> <path> <perm-letters> — 0 if one rule matches the path and holds every
# letter (x means any of ix, Px, Cx, cx, px with or without r).
_aa_allows() {
    local rules="$1" path="$2" want="$3" glob perms rx ok l
    while IFS=$'\t' read -r glob perms; do
        [ -n "$glob" ] || continue
        rx="$(_aa_rx "$glob")"
        [[ $path =~ $rx ]] || continue
        ok=1
        for (( l = 0; l < ${#want}; l++ )); do
            [[ $perms == *"${want:l:1}"* ]] || ok=0
        done
        [ "$ok" -eq 1 ] && return 0
    done <<< "$rules"
    return 1
}
_aa_denied() { _aa_allows "$CHILD_DENIES" "$1" "$2"; }

echo "-- the evaluator itself (so the checks below can fail) --"
assert_success "evaluator: /bin/** matches /bin/busybox for x" _aa_allows $'/bin/**\tix' /bin/busybox x
assert_failure "evaluator: /bin/* does not match /bin/a/b" _aa_allows $'/bin/*\tix' /bin/a/b x
assert_failure "evaluator: an r rule does not grant w" _aa_allows $'/data/**\tr' /data/x w
assert_success "evaluator: braces expand" _aa_allows $'/run/{s6,service}/**\tix' /run/service/x/run x
assert_success "evaluator: @{PROC} is /proc" _aa_allows $'@{PROC}/mounts\tr' /proc/mounts r

echo "-- every program the code runs is catalogued and executable under the profile --"
# Programs the image carries that are not busybox applets (busybox applets all resolve to
# /bin/busybox and are covered by one rule, checked below). name=real path in the image.
declare -A CATALOG=(
    [bash]=/bin/bash [sh]=/bin/busybox [busybox]=/bin/busybox
    [ip]=/sbin/ip [bridge]=/sbin/bridge [ss]=/sbin/ss
    [iptables]=/usr/sbin/xtables-nft-multi [ip6tables]=/usr/sbin/xtables-nft-multi
    [iptables-restore]=/usr/sbin/xtables-nft-multi [ip6tables-restore]=/usr/sbin/xtables-nft-multi
    [iptables-save]=/usr/sbin/xtables-nft-multi [ip6tables-save]=/usr/sbin/xtables-nft-multi
    [nft]=/usr/sbin/nft
    [dnsmasq]=/usr/sbin/dnsmasq
    [modprobe]=/bin/kmod [insmod]=/bin/kmod [rmmod]=/bin/kmod [lsmod]=/bin/kmod [modinfo]=/bin/kmod [kmod]=/bin/kmod
    [dbus-send]=/usr/bin/dbus-send
    [python3]=/usr/bin/python3.12
    [curl]=/usr/bin/curl [jq]=/usr/bin/jq
    [bashio]=/usr/lib/bashio/bashio
    [s6-setuidgid]=/package/admin/s6-2.15.1.0/command/s6-setuidgid
    [s6-svc]=/package/admin/s6-2.15.1.0/command/s6-svc
    [s6-svstat]=/usr/bin/s6-svstat
    [with-contenv]=/package/admin/s6-overlay-3.2.3.2/command/with-contenv
    [hostapd_s1g]=/opt/halow/artifacts/hostapd_s1g
    [hostapd_cli_s1g]=/opt/halow/artifacts/hostapd_cli_s1g
)
# Every non-busybox program in the image (Alpine 3.23 base plus the pinned packages);
# a use of any of these in rootfs/ must be catalogued above.
IMAGE_PROGRAMS="2to3 apk arpaname arptables arptables-nft arptables-nft-restore arptables-nft-save
arptables-restore arptables-save arptables-translate bash bashio bridge c_rehash ctstat curl
dbus-cleanup-sockets dbus-daemon dbus-monitor dbus-run-session dbus-send dbus-test-tool
dbus-update-activation-environment dbus-uuidgen ddns-confgen delv depmod dig dnsmasq dnstap-read
ebtables ebtables-nft ebtables-nft-restore ebtables-nft-save ebtables-restore ebtables-save
ebtables-translate genl getconf getent iconv ifstat insmod ip ip6tables ip6tables-apply ip6tables-nft
ip6tables-nft-restore ip6tables-nft-save ip6tables-restore ip6tables-restore-translate ip6tables-save
ip6tables-translate iptables iptables-apply iptables-nft iptables-nft-restore iptables-nft-save
iptables-restore iptables-restore-translate iptables-save iptables-translate jq kmod ldconfig ldd
lnstat lsmod mdig modinfo modprobe named-checkzone nslookup nstat nsupdate pydoc3 python python3
python3.12 rmmod rtacct rtmon rtstat scanelf ss ssl_client tc tempio update-ca-certificates wcurl
xtables-monitor xtables-nft-multi nft s6-setuidgid with-contenv s6-svc s6-svok s6-svstat s6-svwait
s6-svscanctl s6-applyuidgid s6-envuidgid s6-softlimit s6-notifyoncheck hostapd_s1g hostapd_cli_s1g"

mapfile -t CODE_FILES < <(find "$ROOTFS" -type f \( -name '*.sh' -o -name run -o -name finish \) | sort)
assert_success "there is code to scan" test "${#CODE_FILES[@]}" -gt 10
CODE="$(for f in "${CODE_FILES[@]}"; do sed -E 's/^[[:space:]]*#.*$//; s/[[:space:]]+#[[:space:]].*$//' "$f"; done)"
# _scan_programs <code> — prints every IMAGE_PROGRAMS name used at a command position
# (line start, after ; & | $( then do else if while until exec command ! timeout N,
# the halow_run_logged wrapper or s6-setuidgid <user>), as a ${VAR:-name} default, or as
# the last component of a path.
_scan_programs() {
    local code="$1" prog p
    for prog in $IMAGE_PROGRAMS; do
        p="${prog//./\\.}"
        if grep -qE "(^|[;&|]|\\\$\\(|\\b(then|do|else|if|while|until|exec|command|halow_run_logged|timeout[[:space:]]+[0-9]+|s6-setuidgid[[:space:]]+[^[:space:]]+)[[:space:]]|!)[[:space:]]*\"?${p}([[:space:]]|\$|\\)|;|\")|:-${p}\\}|/${p}([[:space:]\"}]|\$)" <<< "$code"; then
            printf ' %s' "$prog"
        fi
    done
}
neg="$(_scan_programs $'    if tc qdisc add dev x root; then\n        x="$(nstat -a)"\n        y="${HALOW_TC:-ebtables}"\n    fi')"
assert_eq " ebtables nstat tc" "$neg" "negative control: the scan finds uncatalogued programs in command position, in \$( ) and as a default"
assert_eq "" "$(_scan_programs '    halow_log_error "tc is mentioned only in prose"')" "negative control: a program named inside a quoted message is not a use"
found="$(_scan_programs "$CODE")"
echo "  programs found in rootfs/:$found"
for must in ip bridge iptables ip6tables nft dnsmasq dbus-send insmod modprobe python3 s6-setuidgid hostapd_s1g hostapd_cli_s1g; do
    assert_success "the scan finds $must (the scan itself works)" grep -qw -- "$must" <<< "$found"
done
for prog in $found; do
    if [ -n "${CATALOG[$prog]:-}" ]; then
        assert_success "$prog (${CATALOG[$prog]}) is executable under the profile" _aa_allows "$TOP_RULES" "${CATALOG[$prog]}" x
    else
        assert_eq "catalogued" "uncatalogued" "the program '$prog' used in rootfs/ is in this test's catalogue (add it, with its real path, and a profile rule)"
    fi
done
for prog in sh bash busybox kmod bashio with-contenv curl iptables-restore ip6tables-restore; do
    assert_success "$prog (${CATALOG[$prog]}) is executable under the profile" _aa_allows "$TOP_RULES" "${CATALOG[$prog]}" x
done
# The helper program that an earlier hostapd release line ran by bare name is no longer
# shipped: the profile has no rule for it, the catalogue does not list it, and nothing in
# rootfs/ runs it.
assert_failure "the profile has no execute rule for the removed helper program" grep -qi 'morse_cli' <<< "$RULES"
assert_failure "the removed helper program is not in the catalogue" bash -c '[ -n "${CATALOG[morse_cli]:-}" ]'
assert_failure "nothing in rootfs/ runs the removed helper program" grep -qi 'morse_cli' <<< "$CODE"
assert_success "the profile does grant the two bundled programs" bash -c 'grep -q "/opt/halow/artifacts/hostapd_s1g ix," <<< "$0" && grep -q "/opt/halow/artifacts/hostapd_cli_s1g ix," <<< "$0"' "$RULES"
assert_success "s6-overlay's init is executable" _aa_allows "$TOP_RULES" /init x
assert_success "the s6 halt used by the manager's finish is executable" _aa_allows "$TOP_RULES" /run/s6/basedir/bin/halt x
assert_success "the service scripts are executable" _aa_allows "$TOP_RULES" /etc/services.d/manager/run x
assert_success "python3 moves into the status child profile" grep -qE '^[[:space:]]*/usr/bin/python3\.12 cx -> halow_status,$' <<< "$RULES"
assert_failure "nothing else is executed outside the inherit/child modes (no Px into other profiles)" grep -qE '[[:space:]][pP]i?x[[:space:]]*(->|,)' <<< "$RULES"

echo "-- file accesses the code performs are permitted --"
while read -r perm path; do
    [ -n "$perm" ] || continue
    assert_success "permits $perm on $path" _aa_allows "$TOP_RULES" "$path" "$perm"
done <<'EOF'
r /usr/lib/halow/manager.sh
r /usr/lib/halow/status/status_server.py
r /usr/share/halow/radio_profiles.psv
r /usr/share/halow/guard_manifest.psv
r /opt/halow/artifacts/morse.ko
r /opt/halow/artifacts/MANIFEST.sha256
r /opt/halow/artifacts/bcf/bcf_boardtype_0807.bin
r /data/options.json
rw /data/halow_state/owns/module_morse
rw /data/halow_state/boot_id
rw /data/halow_fw/morse/mm8108b2-rl.bin
rw /data/halow_leases/dnsmasq.leases
rw /data/halow_leases/dnsmasq.leases.tmp.12345
rw /run/halow/status.json
rw /run/halow/hostapd.conf
rw /run/halow/dnsmasq.leases
rw /run/hostapd/wlan0
rw /var/run/hostapd/wlan0
rw /run/s6-linux-init-container-results/exitcode
rw /tmp/tmp.abc123
r /lib/modules/6.18.52-haos/modules.dep.bin
r /lib/modules/6.18.52-haos/kernel/net/mac80211/mac80211.ko.xz
r /proc/mounts
r /proc/self/mountinfo
r /proc/modules
r /proc/sys/kernel/random/boot_id
r /proc/sys/net/ipv4/ip_forward
r /proc/1234/cmdline
r /proc/1234/exe
r /proc/
r /proc/sys/net/ipv6/conf/wlu1/disable_ipv6
rw /proc/sys/net/ipv6/conf/wlu1/disable_ipv6
rw /proc/sys/net/ipv6/conf/wlu1.sta1/disable_ipv6
rw /proc/sys/net/ipv6/conf/halow-br0/disable_ipv6
rw /run/s6/container_environment/SUPERVISOR_TOKEN
x /etc/cont-init.d/00-restrict-container-environment
r /sys/class/net/wlan0/address
r /sys/bus/usb/devices/1-1/idVendor
r /sys/devices/platform/soc/usb1/1-1/idProduct
r /sys/module/dot11ah/parameters/channelization_scheme
r /sys/module/mac80211/srcversion
rw /sys/module/firmware_class/parameters/path
r /etc/hostname
rw /run/dbus/system_bus_socket
r /dev/kmsg
EOF

echo "-- host paths the profile does not grant --"
while read -r perm path; do
    [ -n "$perm" ] || continue
    assert_failure "does not permit $perm on $path" _aa_allows "$TOP_RULES" "$path" "$perm"
done <<'EOF'
r /etc/shadow
w /etc/passwd
w /usr/lib/halow/manager.sh
w /opt/halow/artifacts/morse.ko
w /lib/modules/6.18.52-haos/modules.dep
w /sys/module/mac80211/parameters/x
w /sys/kernel/debug/x
w /sys/devices/platform/x
w /sys/class/net/eth0/mtu
w /proc/sys/kernel/modprobe
w /proc/sys/net/ipv6/conf/all/forwarding
w /proc/sys/net/ipv6/conf/wlu1/forwarding
w /proc/sys/net/ipv6/conf/wlu1/accept_ra
w /proc/sys/net/ipv4/conf/all/forwarding
w /proc/sysrq-trigger
r /root/.ssh/id_rsa
r /mnt/data/supervisor/x
r /share/x
r /config/configuration.yaml
r /dev/sda
x /opt/halow/artifacts/morse.ko
x /data/halow_fw/morse/mm8108b2-rl.bin
x /tmp/evil
EOF

echo "-- host-wide IPv6 switches stay out of reach (deny rules win over the per-interface grant) --"
TOP_DENIES="$(_aa_denies top)"
for p in /proc/sys/net/ipv6/conf/all/disable_ipv6 /proc/sys/net/ipv6/conf/default/disable_ipv6; do
    assert_success "control: the per-interface grant alone would match $p" _aa_allows "$TOP_RULES" "$p" w
    assert_success "an explicit deny forbids writing $p" _aa_allows "$TOP_DENIES" "$p" w
done
assert_failure "the deny does not cover an interface's own entry" _aa_allows "$TOP_DENIES" /proc/sys/net/ipv6/conf/wlu1/disable_ipv6 w
assert_failure "the deny does not forbid reading the host-wide entries" _aa_allows "$TOP_DENIES" /proc/sys/net/ipv6/conf/all/disable_ipv6 r

# A mount rule names a source and/or a mount point; a rule with only one of them matches any
# value of the other. _aa_mount_hits <allow|deny> <source> <target> — 0 if some rule of that
# kind in the top-level profile matches the pair (mount options are not evaluated).
_aa_mount_hits() {
    local kind="$1" src="$2" dst="$3" line s sg dg
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        s="${line#"${line%%[![:space:]]*}"}"
        s="${s#deny }"; s="${s#mount }"
        s="$(sed -E 's/options in \([^)]*\)//; s/options=\([^)]*\)//; s/fstype=[^ ]+//; s/,[[:space:]]*$//; s/^[[:space:]]+//; s/[[:space:]]+$//' <<< "$s")"
        case "$s" in
            *'->'*) sg="$(sed -E 's/[[:space:]]*->.*$//' <<< "$s")"; dg="$(sed -E 's/^.*->[[:space:]]*//' <<< "$s")" ;;
            *) sg="$s"; dg="" ;;
        esac
        if [ -n "$sg" ]; then [[ $src =~ $(_aa_rx "$sg") ]] || continue; fi
        if [ -n "$dg" ]; then [[ $dst =~ $(_aa_rx "$dg") ]] || continue; fi
        return 0
    done < <(if [ "$kind" = deny ]; then grep -E '^[[:space:]]*deny[[:space:]]+mount[[:space:]]' <<< "$RULES"; else grep -E '^[[:space:]]*mount[[:space:]]+options in' <<< "$RULES"; fi)
    return 1
}
# _aa_bind_ok <source> <target> — 0 when a bind mount is permitted: an allow rule matches
# and no explicit deny does (an explicit deny always wins).
_aa_bind_ok() { _aa_mount_hits allow "$1" "$2" && ! _aa_mount_hits deny "$1" "$2"; }
CP=/proc/sys/net/ipv6/conf
echo "-- a bind mount must not reach the host-wide switches from either side --"
assert_success "the bracket's own bind (an interface's file onto itself) is permitted" _aa_bind_ok "$CP/wlu1/disable_ipv6" "$CP/wlu1/disable_ipv6"
assert_failure "evaluator control: a path outside the pattern is not permitted" _aa_bind_ok "$CP/wlu1/accept_ra" "$CP/wlu1/accept_ra"
for t in all default; do
    assert_success "control: the allow rule alone would let another interface's file be bound onto $t" _aa_mount_hits allow "$CP/wlu1/disable_ipv6" "$CP/$t/disable_ipv6"
    assert_failure "another interface's file cannot be bound onto the $t entry" _aa_bind_ok "$CP/wlu1/disable_ipv6" "$CP/$t/disable_ipv6"
    assert_success "control: the allow rule alone would let the $t entry be bound onto an interface's file" _aa_mount_hits allow "$CP/$t/disable_ipv6" "$CP/wlu1/disable_ipv6"
    assert_failure "the $t entry cannot be bound onto an interface's file" _aa_bind_ok "$CP/$t/disable_ipv6" "$CP/wlu1/disable_ipv6"
    assert_failure "the $t entry cannot be bound onto itself" _aa_bind_ok "$CP/$t/disable_ipv6" "$CP/$t/disable_ipv6"
done
assert_failure "all cannot be bound onto default" _aa_bind_ok "$CP/all/disable_ipv6" "$CP/default/disable_ipv6"
assert_success "an interface literally named like 'allx' is still an ordinary interface" _aa_bind_ok "$CP/allx/disable_ipv6" "$CP/allx/disable_ipv6"

echo "-- /proc/[0-9]* can expand under enforcement --"
assert_success "the /proc directory listing itself is readable (@{PROC}/ r)" grep -qE '^[[:space:]]*@\{PROC\}/ r,$' <<< "$RULES"
assert_failure "control: a per-process rule alone does not grant the listing" _aa_allows $'@{PROC}/[0-9]*/cmdline\tr' /proc/ r

echo "-- the status server's child profile: no capabilities, read-only --"
child_block="$(awk '/^[[:space:]]+profile halow_status/ {p=1} p {print} p && /^[[:space:]]+}[[:space:]]*$/ {exit}' "$PROFILE")"
assert_success "the child profile halow_status exists with the required flags" \
    grep -qE '^[[:space:]]+profile halow_status flags=\(attach_disconnected,mediate_deleted\) \{' <<< "$child_block"
assert_failure "the child profile grants no capability" grep -qE '^[[:space:]]*capability' <<< "$child_block"
assert_failure "the child profile has no execute permission" bash -c 'grep -vE "^[[:space:]]*deny" <<< "$0" | grep -qE "[[:space:]][a-zA-Z]*x[a-zA-Z]*(,|[[:space:]]*->)"' "$child_block"
assert_failure "the child profile has no write permission except to its own liveness counter" bash -c 'grep -vE "^[[:space:]]*(deny|signal|network|#)" <<< "$0" | grep -vE "^[[:space:]]*/run/halow-status/heartbeat(\.tmp)? rw,$" | grep -qE "[[:space:]][a-z]*[wa][a-z]*,"' "$child_block"
assert_failure "the child profile has no raw or packet sockets" grep -qE 'network (packet|netlink|inet6? raw)' <<< "$child_block"
for path in /run/halow/status.json /usr/lib/halow/status/status_server.py /usr/lib/halow/status/page.html /usr/lib/python3.12/json/__init__.py /usr/bin/python3.12; do
    assert_success "the status server may read $path" _aa_allows "$CHILD_RULES" "$path" r
done
for path in /run/halow/hostapd.conf /data/options.json /data/halow_state/owns/x /data/halow_leases/dnsmasq.leases /sys/module/firmware_class/parameters/path /run/dbus/system_bus_socket; do
    assert_failure "the status server may not read $path" _aa_allows "$CHILD_RULES" "$path" r
done
assert_success "the rendered access-point configuration is explicitly denied to the status server" _aa_denied /run/halow/hostapd.conf r

echo "-- the status service's liveness directory and the manager's direct supervision: the rules, and nothing broader --"
HB_DEFAULT="$(sed -n 's/^: "\${HALOW_STATUS_HEARTBEAT_FILE:=\${HALOW_STATUS_HEARTBEAT_DIR}\/heartbeat}"$/heartbeat/p' ../rootfs/usr/lib/halow/constants.sh)"
HB_DIR_DEFAULT="$(sed -n 's/^: "\${HALOW_STATUS_HEARTBEAT_DIR:=\([^}]*\)}"$/\1/p' ../rootfs/usr/lib/halow/constants.sh)"
assert_eq "heartbeat" "$HB_DEFAULT" "constants.sh names the counter file 'heartbeat' in its directory"
assert_eq "/run/halow-status" "$HB_DIR_DEFAULT" "the liveness directory is /run/halow-status (not under /run/halow, which the status user cannot write)"
HB="$HB_DIR_DEFAULT/$HB_DEFAULT"
assert_eq "$HB.tmp" "$HB_DIR_DEFAULT/heartbeat.tmp" "(the server writes <file>.tmp and renames it)"
assert_success "the server writes the temporary name the profile lists (path + \".tmp\")" grep -qF 'tmp = path + ".tmp"' ../rootfs/usr/lib/halow/status/status_server.py
write_rules="$(awk -F'\t' '$2 ~ /[wa]/ {print $1}' <<< "$CHILD_RULES" | sort | tr '\n' ' ')"
assert_eq "$HB $HB.tmp " "$write_rules" "the status child may write exactly its counter file and the temporary name beside it"
assert_success "the status child may read its own directory" _aa_allows "$CHILD_RULES" "$HB_DIR_DEFAULT/" r
assert_success "the status child may create and rename the counter (rw)" _aa_allows "$CHILD_RULES" "$HB" rw
assert_success "the status child may create and remove the temporary name (rw)" _aa_allows "$CHILD_RULES" "$HB.tmp" rw
for p in "$HB_DIR_DEFAULT/other" "$HB_DIR_DEFAULT/heartbeat.tmp.2" "$HB_DIR_DEFAULT/sub/heartbeat" "/run/halow-status-x/heartbeat" /run/halow/status.json /run/halow/heartbeat /run/heartbeat /tmp/heartbeat /data/heartbeat /usr/lib/halow/status/status_server.py /etc/passwd /run/s6/container_environment/SUPERVISOR_TOKEN; do
    assert_failure "the status child may not write $p" _aa_allows "$CHILD_RULES" "$p" w
done
for p in "$HB_DIR_DEFAULT/other" /run/s6/container_environment/SUPERVISOR_TOKEN /data/options.json; do
    assert_failure "the status child may not read $p" _aa_allows "$CHILD_RULES" "$p" r
done
assert_failure "no wildcard in any write rule of the status child" bash -c 'awk -F"\t" "\$2 ~ /[wa]/ {print \$1}" <<< "$0" | grep -q "[*?{]"' "$CHILD_RULES"
assert_failure "the status child still has no network family other than inet and inet6 stream" bash -c 'grep -E "^[[:space:]]*network" <<< "$0" | grep -vE "network inet6? stream,$"' "$child_block"
assert_eq "3" "$(grep -cE '^[[:space:]]*/run/halow-status' <<< "$child_block")" "the status child has exactly three rules for the directory (directory, counter, temporary name)"
assert_eq "3" "$(grep -c 'halow-status' <<< "$RULES")" "no rule outside those three names the liveness directory (the manager reaches it through its existing /run rule)"
assert_success "the manager (parent profile) may read the counter through its existing /run rule" _aa_allows "$TOP_RULES" "$HB" r
for p in /proc/4300/cmdline /proc/4300/status; do
    assert_success "the manager may read $p" _aa_allows "$TOP_RULES" "$p" r
done
assert_success "the manager may read the kernel's TCP table" _aa_allows "$TOP_RULES" /proc/net/tcp r
assert_success "...and the same table through the per-process path" _aa_allows "$TOP_RULES" /proc/4300/net/tcp r
assert_failure "the manager has no write rule on the TCP table" _aa_allows "$TOP_RULES" /proc/net/tcp w
assert_success "s6-svstat is executable (the existing /usr/bin/** rule)" _aa_allows "$TOP_RULES" "${CATALOG[s6-svstat]}" x
assert_failure "the profile has no rule that names s6-svstat or s6-svc individually (no new exec rule was needed)" grep -qE 's6-svstat|s6-svc' <<< "$RULES"
# Nothing broader than before this change: the counts below are those of the profile before
# the liveness directory was added, plus only the two child write rules and the directory rule.
assert_eq "20" "$(grep -cE '[[:space:]][a-zA-Z]*x([[:space:]]*->[^,]*)?,$' <<< "$RULES")" "the number of execute rules is 20: the earlier 21 (which included /usr/sbin/nft) minus the rule for the helper program that is no longer shipped"
assert_eq "14" "$(grep -cE '^[[:space:]]*network ' <<< "$RULES")" "the number of network rules is unchanged (14)"
assert_eq "14" "$(grep -cE '^[[:space:]]*capability ' <<< "$RULES")" "the number of capability rules is unchanged (14)"
assert_eq "16" "$(grep -cE '^[[:space:]]*(owner )?[/@][^ ]* [a-z]*w[a-z]*,$' <<< "$RULES")" "the number of write rules grew by exactly the two child rules (14 + 2)"
assert_eq "2" "$(grep -cE '^[[:space:]]*mount ' <<< "$RULES")" "still two mount rules (the tmpfs and the IPv6 bracket bind; neither the nft change nor the evidence update added one)"
assert_failure "the status child does not gain any execute, capability, ptrace, mount, dbus or unix rule" grep -qE '^[[:space:]]*(capability|ptrace|mount|remount|umount|dbus|unix|network (unix|netlink|packet))' <<< "$child_block"
# The two profile header lines are exactly the lines a complain-mode run edits.
assert_eq "profile $slug flags=(attach_disconnected,mediate_deleted) {" "$(grep -E '^profile ' "$PROFILE")" "the top-level header line is unchanged (the line a complain-mode run edits)"
assert_eq "  profile halow_status flags=(attach_disconnected,mediate_deleted) {" "$(grep -E '^  profile halow_status ' "$PROFILE")" "the child header line is unchanged (the other line a complain-mode run edits)"

echo "-- read opens observed in complain mode (no adapter present, access point up) are granted, and nothing beyond them --"
S6=/package/admin/s6-overlay-3.2.3.2
while read -r perm path; do
    [ -n "$perm" ] || continue
    assert_success "complain-mode evidence: permits $perm on $path" _aa_allows "$TOP_RULES" "$path" "$perm"
done <<EOF
r /init
r $S6/command/printcontenv
r $S6/command/with-contenv
r $S6/libexec/preinit
r $S6/libexec/stage0
r $S6/etc/s6-linux-init/skel/rc.init
r $S6/etc/s6-linux-init/skel/rc.shutdown
r $S6/etc/s6-linux-init/skel/rc.shutdown.final
r $S6/etc/s6-rc/sources/
r $S6/etc/s6-rc/sources/top/
r $S6/etc/s6-rc/sources/top/type
r $S6/etc/s6-rc/sources/top/contents.d/
r $S6/etc/s6-rc/sources/legacy-services/dependencies.d/
r $S6/etc/s6-rc/sources/legacy-services/down
r $S6/etc/s6-rc/sources/legacy-cont-init/up
r $S6/etc/s6-rc/sources/fix-attrs/type
r $S6/etc/s6-rc/sources/base/contents.d/
r $S6/etc/s6-rc/scripts/cont-init
r $S6/etc/s6-rc/scripts/fix-attrs
r $S6/etc/s6-rc/scripts/services-up
r $S6/etc/s6-rc/scripts/services-down
r $S6/etc/s6-rc/scripts/cont-finish
r /etc/services.d/
r /etc/fix-attrs.d/
r /etc/cont-init.d/
r /etc/nsswitch.conf
EOF
while read -r perm path; do
    [ -n "$perm" ] || continue
    assert_success "complain-mode evidence: the status child permits $perm on $path" _aa_allows "$CHILD_RULES" "$path" "$perm"
done <<'EOF'
r /etc/ssl/openssl.cnf
r /etc/resolv.conf
r /etc/hosts
EOF
# Observer-only accesses (the investigator's own docker exec commands) and everything outside
# the evidenced s6 tree must stay ungranted.
for p in /root/ /root/.ssh/id_rsa /proc/4242/attr/current /proc/1/attr/current /usr/bin/; do
    assert_failure "observer-only path not granted: r on $p" _aa_allows "$TOP_RULES" "$p" r
done
for p in /package/admin/s6-2.15.1.0/command/s6-svc /package/admin/s6-overlay-3.2.3.2/command/s6-rc /package/admin/s6-overlay-3.2.3.2/libexec/other /package/admin/s6-overlay-9.9.9.9/command/printcontenv /package/admin/s6-overlay-3.2.3.2/etc/s6-rc/scripts/other /package/admin/s6-overlay-3.2.3.2/etc/other; do
    assert_failure "no read rule beyond the evidenced s6 paths: r on $p (the ix rule does not grant r)" _aa_allows "$TOP_RULES" "$p" r
done
for p in /etc/shadow /etc/ssl/private/key.pem /etc/fix-attrs.d/x; do
    assert_failure "the child gains no read of $p" _aa_allows "$CHILD_RULES" "$p" r
done
assert_failure "the child does not gain /etc/nsswitch.conf (not observed for it)" _aa_allows "$CHILD_RULES" /etc/nsswitch.conf r
for p in /init "$S6/command/printcontenv" "$S6/etc/s6-rc/sources/top/type" "$S6/etc/s6-rc/scripts/cont-init" /etc/nsswitch.conf; do
    assert_failure "the new read rules grant no write on $p" _aa_allows "$TOP_RULES" "$p" w
done
for p in "$S6/command/printcontenv" "$S6/etc/s6-rc/sources/top/type" "$S6/libexec/stage0"; do
    assert_success "execute on $p is still the existing /package/** ix rule" _aa_allows "$TOP_RULES" "$p" x
done
# Every new rule is read-only, names exactly the evidenced tree, and adds no wildcard outside
# the s6 sources directory.
new_rules="$(grep -E '^[[:space:]]*(/init r,|/package/admin/s6-overlay-3\.2\.3\.2/|/etc/(services\.d|fix-attrs\.d|cont-init\.d)/ r|/etc/nsswitch\.conf)' <<< "$RULES" | grep -vE '^[[:space:]]*/etc/(services|cont-init|cont-finish)\.d/\*\*')"
assert_eq "11" "$(grep -c . <<< "$new_rules")" "eleven new read rules under the evidenced prefixes"
assert_failure "every new rule is read-only (r)" bash -c 'grep -vE " r,$" <<< "$0"' "$new_rules"
assert_failure "only the s6 sources rule uses ** (no other new wildcard tree)" bash -c 'grep -F "**" <<< "$0" | grep -vF "/etc/s6-rc/sources/{,**} r,"' "$new_rules"
assert_eq "20" "$(grep -cE '[[:space:]][a-zA-Z]*x([[:space:]]*->[^,]*)?,$' <<< "$RULES")" "still 20 execute rules after the evidence update (the helper program rule is gone)"
assert_eq "16" "$(grep -cE '^[[:space:]]*(owner )?[/@][^ ]* [a-z]*w[a-z]*,$' <<< "$RULES")" "still 16 write rules after the evidence update"
assert_eq "14" "$(grep -cE '^[[:space:]]*capability ' <<< "$RULES")" "still 14 capability rules after the evidence update"
assert_eq "4" "$(grep -cE '^[[:space:]]*deny[[:space:]]' <<< "$child_block")" "the child's four deny rules are unchanged"
assert_eq "11" "$(grep -cE '^[[:space:]]*deny[[:space:]]' <<< "$RULES")" "the deny rules: pivot_root, ipv6 write all/default, mount (both ends, either end), remount and umount of all/default, and the child's four"
assert_eq "10" "$(grep -c 'ipv6' <<< "$RULES")" "the ipv6 rules: the per-interface grant and its deny, the three bracket allows and the five all/default denies"
assert_failure "the profile is still not in complain mode" grep -qiE 'complain' <<< "$RULES"

echo "-- syntax --"
if command -v apparmor_parser >/dev/null 2>&1; then
    # -Q parse and compile without loading into a kernel; -K/-T no cache. Needs no root.
    if out="$(apparmor_parser -Q -K -T "$PROFILE" 2>&1)"; then pr=0; else pr=$?; fi
    assert_eq "0" "$pr" "apparmor_parser accepts the profile ($(apparmor_parser --version 2>/dev/null | head -n1))${out:+: $out}"
    bad="$(mktemp)"
    sed 's/^  capability sys_module,$/  capability sys_module/' "$PROFILE" > "$bad"
    assert_failure "negative control: apparmor_parser rejects a profile with a broken rule" apparmor_parser -Q -K -T "$bad"
    rm -f "$bad"
else
    echo "  note: apparmor_parser is not installed here; the syntax check was SKIPPED"
fi

echo "test_apparmor: $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed"
exit $([ "$HALOW_TEST_FAILURES" -eq 0 ] && echo 0 || echo 1)
