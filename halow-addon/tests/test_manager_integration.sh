#!/usr/bin/env bash
# The manager wired to the REAL libraries of every subsystem (status snapshot, radio, guard,
# adapter, bridge, backend, dnsmasq, stations, firewall, allow-list, uplink, and the
# privileged module/firmware/NetworkManager/hostapd code). Only what touches the host is
# faked: external commands first on PATH (insmod, rmmod, modprobe, lsmod, dmesg, mount,
# dbus-send, ip, bridge, ss, dnsmasq, uname, modinfo, iptables/ip6tables), the hostapd
# binaries in the artifacts directory, and the sysfs/proc trees through their documented
# path variables. The module-parameter read of the driver load uses the fixed path
# /sys/module, so the manager runs in a private user and mount namespace (unshare) with a
# fake tree bind-mounted there; nothing outside the namespace is changed.
#
# This suite depends on every subsystem having landed its contract; it reports SKIP
# (not success) when the namespace tools are unavailable.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh
. ./helpers_radio.sh
. ./helpers_adapter.sh

echo "== test_manager_integration =="
TESTS_DIR="$(pwd)"

if ! unshare -rm true 2>/dev/null; then
    echo "  SKIP: unprivileged user and mount namespaces are not available here; this suite did not run"
    echo "test_manager_integration: 0/0 passed (skipped)"
    exit 77
fi

world() {
    halow_test_setup >/dev/null 2>&1 || true
    W="$HALOW_TEST_TMP/world"; B="$W/bin"
    mkdir -p "$B" "$W/sysmod" "$W/usbdev/1-1/1-1:1.0" "$W/usb" "$W/modules" "$HALOW_RUN_DIR"
    export W
    . ./doubles/fakes_env.sh; HALOW_FAKE_BIN="$W/mntbin"; halow_fakes_mnt_install; export HALOW_FAKE_BIN
    export HALOW_SYS_MODULE_DIR="$W/sysmod"
    export HALOW_SYS_USB_DIR="$W/usb"
    export HALOW_PROC_MOUNTS="$W/mounts"
    export HALOW_HOSTAPD_CTRL_DIR="$W/ctrl"
    export HALOW_IP=ip HALOW_BRIDGE_CMD=bridge HALOW_SS=ss
    export HALOW_FAKE_LOG="$W/fake.calls"
    export HALOW_ACS_TIMEOUT_S=20 HALOW_AP_ENABLED_TIMEOUT_S=15 HALOW_ADAPTER_NETDEV_TIMEOUT_S=10
    export HALOW_DNSMASQ_STABLE_S=1
    printf 'sysfs /sys sysfs ro 0 0\n' > "$W/mounts"
    # per-interface IPv6 switches of the interfaces the add-on will use (all on: 0)
    export HALOW_PROC_SYS_DIR="$W/procsys"
    mkdir -p "$W/procsys/net/ipv6/conf/wlu1" "$W/procsys/net/ipv6/conf/halow-br0"
    printf '0\n' > "$W/procsys/net/ipv6/conf/wlu1/disable_ipv6"; printf '0\n' > "$W/procsys/net/ipv6/conf/halow-br0/disable_ipv6"
    printf '1\n' > "$HALOW_IP_FORWARD_FILE"
    printf '11111111-2222-3333-4444-555555555555\n' > "$HALOW_BOOT_ID_FILE"
    # a kernel log that already holds earlier records with kernel timestamps (the load's
    # kernel-log marker is the newest of them); $W/clock is the fake uptime in seconds
    : > "$W/mods"; : > "$HALOW_FAKE_LOG"
    : > "$W/dmesg"
    for _i in 1 2 3 4 5 6 7 8 9 10; do
        printf '[%7d.%06d] hassio: port 5(vethf120b12) entered forwarding state\n' "$((10 + _i))" "$((_i * 11111))" >> "$W/dmesg"
    done
    printf '300\n' > "$W/clock"
    mkdir -p "$HALOW_SYS_CLASS_NET_DIR/end0"

    # USB adapter 325b:8100
    printf '325b\n' > "$W/usbdev/1-1/idVendor"; printf '8100\n' > "$W/usbdev/1-1/idProduct"
    printf '1\n' > "$W/usbdev/1-1/busnum"; printf '2\n' > "$W/usbdev/1-1/devnum"
    ln -s "$W/usbdev/1-1" "$W/usb/1-1"; ln -s "$W/usbdev/1-1/1-1:1.0" "$W/usb/1-1:1.0"

    # kernel, guard manifest, bundled modules: the guard's fake host (exact module files with
    # their SHA-256 values, banner, configuration) and its fake modinfo/uname
    hat_guard_world "$W/gw" "$HALOW_ARTIFACTS_DIR"
    cp "$HAT_GW_BIN/modinfo" "$HAT_GW_BIN/uname" "$B/"
    printf 'main fw' > "$HALOW_ARTIFACTS_DIR/${HALOW_FW_MAIN_NAME}"
    mkdir -p "$HALOW_ARTIFACTS_DIR/bcf"; printf 'bcf fw' > "$HALOW_ARTIFACTS_DIR/bcf/${HALOW_FW_BCF_NAME}"
    # what the fake driver reports for the board file (the file's own size and CRC-32, as
    # the real driver does); a test may overwrite bcf.crc / ring_full before the run
    printf '%s' "${HALOW_FW_BCF_NAME}" > "$W/bcf.name"
    wc -c < "$HALOW_ARTIFACTS_DIR/bcf/${HALOW_FW_BCF_NAME}" | tr -d ' ' > "$W/bcf.size"
    python3 -c 'import sys,zlib; print("0x%08x" % zlib.crc32(open(sys.argv[1],"rb").read()))' \
        "$HALOW_ARTIFACTS_DIR/bcf/${HALOW_FW_BCF_NAME}" > "$W/bcf.crc"

    cat > "$B/lsmod" <<'EOF'
#!/bin/bash
echo "Module Size Used by"; cat "$W/mods"
EOF
    cat > "$B/insmod" <<'EOF'
#!/bin/bash
echo "insmod $*" >> "$W/host.calls"
m="$(basename "$1" .ko)"
echo "$m 1000 0" >> "$W/mods"
mkdir -p "/sys/module/$m"; : > "/sys/module/$m/initstate"
case "$m" in
    dot11ah)
        mkdir -p /sys/module/dot11ah/parameters
        for a in "$@"; do case "$a" in channelization_scheme=*) echo "${a#*=}" > /sys/module/dot11ah/parameters/channelization_scheme ;; esac; done ;;
    morse)
        mkdir -p "$W/usbdev/1-1/1-1:1.0/net/wlu1" "$HALOW_SYS_CLASS_NET_DIR/wlu1"
        ln -sfn "$W/usbdev/1-1" "$HALOW_SYS_CLASS_NET_DIR/wlu1/device"
        # the driver's own records, as measured on the reference device (kernel timestamps included)
        t="$(cat "$W/clock")"; echo "$((t + 2))" > "$W/clock"
        {
            printf '[%7d.%06d] morse micro driver registration. Version 0-rel_mm8108_2_1_0_2026_Jul_01\n' "$t" 543372
            printf '[%7d.%06d] morse_usb 1-1:1.0: Loaded firmware from morse/mm8108b2-rl.bin, size 501348, crc32 0x5152467b\n' "$t" 561224
            printf '[%7d.%06d] morse_usb 1-1:1.0: Loaded BCF from morse/%s, size %s, crc32 %s\n' "$t" 561563 "$(cat "$W/bcf.name")" "$(cat "$W/bcf.size")" "$(cat "$W/bcf.crc")"
            printf '[%7d.%06d] morse_usb 1-1:1.0: Driver loaded with kernel module parameters\n' "$((t + 1))" 531837
        } >> "$W/dmesg"
        # ring_full: the kernel log is full, so every new record evicts an old one and the
        # total line count does NOT grow (a defect observed on a long-running device)
        # wipe_log: the kernel log is cleared (by someone else) during the load, so the
        # records of this attempt cannot be proven
        [ -e "$W/wipe_log" ] && : > "$W/dmesg"
        [ -e "$W/ring_full" ] && { tail -n +5 "$W/dmesg" > "$W/dmesg.tmp"; mv "$W/dmesg.tmp" "$W/dmesg"; } ;;
esac
exit 0
EOF
    cat > "$B/modprobe" <<'EOF'
#!/bin/bash
echo "modprobe $*" >> "$W/host.calls"
# like the real modprobe, mac80211 brings its dependency libarc4
[ "$1" = "mac80211" ] && printf 'libarc4 1000 1 mac80211\nmac80211 1000 0\n' >> "$W/mods"
exit 0
EOF
    cat > "$B/rmmod" <<'EOF'
#!/bin/bash
echo "rmmod $*" >> "$W/host.calls"
grep -v "^$1 " "$W/mods" > "$W/mods.tmp"; mv "$W/mods.tmp" "$W/mods"
rm -rf "/sys/module/$1"
[ "$1" = "morse" ] && rm -rf "$W/usbdev/1-1/1-1:1.0/net" "$HALOW_SYS_CLASS_NET_DIR/wlu1"
exit 0
EOF
    cat > "$B/dmesg" <<'EOF'
#!/bin/bash
cat "$W/dmesg"
EOF
    cat > "$B/mount" <<'EOF'
#!/bin/bash
echo "mount $*" >> "$W/host.calls"
case "$*" in
    "-o remount,bind,rw /sys") sed -i 's|^sysfs /sys sysfs r[ow] |sysfs /sys sysfs rw |' "$W/mounts" ;;
    "-o remount,bind,ro /sys") sed -i 's|^sysfs /sys sysfs r[ow] |sysfs /sys sysfs ro |' "$W/mounts" ;;
    "-t tmpfs -o mode=0755,size="*",nosuid,nodev,noexec tmpfs $HALOW_RUN_DIR")
        # recorded only: a real mount here would hide the run directory from this test
        echo "tmpfs $HALOW_RUN_DIR tmpfs rw,nosuid,nodev,noexec 0 0" >> "$W/mounts" ;;
    *disable_ipv6*) exec "$HALOW_FAKE_BIN/mount" "$@" ;;
    *) exit 1 ;;
esac
EOF
    cat > "$B/umount" <<'EOF'
#!/bin/bash
exec "$HALOW_FAKE_BIN/umount" "$@"
EOF
    cat > "$B/dbus-send" <<'EOF'
#!/bin/bash
case "$*" in
    *GetDeviceByIpIface*)
        i="${*: -1}"; i="${i#string:}"
        case "$i" in
            wlu1) echo '   object path "/org/freedesktop/NetworkManager/Devices/7"' ;;
            *) echo "Error org.freedesktop.NetworkManager.UnknownDevice: No device found"; exit 1 ;;
        esac ;;
    *Properties.Get*) echo "   variant       boolean $(cat "$W/nm7" 2>/dev/null || echo true)" ;;
    *Properties.Set*) for a in "$@"; do case "$a" in variant:boolean:*) echo "${a#variant:boolean:}" > "$W/nm7" ;; esac; done ;;
    *) exit 1 ;;
esac
EOF
    cat > "$B/ip" <<EOF
#!/bin/bash
case "\$*" in
    *"route show"*|*"route list"*)
        echo "default via 192.168.1.1 dev end0 proto dhcp"
        echo "192.168.1.0/24 dev end0 proto kernel scope link src 192.168.1.10"; exit 0 ;;
    "-o -4 addr show"|"-o -4 addr"|"-4 -o addr show")
        echo "2: end0    inet 192.168.1.10/24 brd 192.168.1.255 scope global end0"; exit 0 ;;
esac
exec bash "$TESTS_DIR/doubles/bin/ip" "\$@"
EOF
    cp "$TESTS_DIR/doubles/bin/bridge" "$TESTS_DIR/doubles/bin/ss" "$TESTS_DIR/doubles/bin/dnsmasq" "$B/"
    printf '#!/bin/bash\necho "s6-svc $*" >> "$W/host.calls"\n' > "$B/s6-svc"
    # hostapd: a real long-lived process named hostapd_s1g with the configuration on its
    # command line; it reports selection completion (automatic) and AP-ENABLED in its log.
    cat > "$HALOW_ARTIFACTS_DIR/hostapd_s1g" <<'EOF'
#!/bin/bash
log=""; conf=""
while [ $# -gt 0 ]; do case "$1" in -f) log="$2"; shift 2 ;; *) conf="$1"; shift ;; esac; done
trap 'exit 0' TERM
if grep -q '^channel=acs_survey' "$conf"; then
    echo "wlu1: ACS-STARTED" >> "$log"
    if [ -e "$W/acs_fail" ]; then echo "wlu1: ACS-FAILED" >> "$log"; else cat "$W/acs_line" >> "$log"; fi
    [ -e "$W/acs_fail" ] && { while :; do sleep 0.2; done; }
fi
echo "wlu1: AP-ENABLED" >> "$log"
while :; do sleep 0.2; done
EOF
    cat > "$HALOW_ARTIFACTS_DIR/hostapd_cli_s1g" <<'EOF'
#!/bin/bash
for a in "$@"; do last="$a"; done
case "$last" in
    status) cat "$W/status" ;;
    relog) echo OK ;;
    all_sta) : ;;
    *) exit 1 ;;
esac
EOF
    chmod +x "$B"/* "$HALOW_ARTIFACTS_DIR/hostapd_s1g" "$HALOW_ARTIFACTS_DIR/hostapd_cli_s1g"
    # the shipped access-point template when the artifacts are staged, otherwise the radio
    # suites' fixture holding the template's active lines
    radio_install_template
    echo "    (access-point template: $RADIO_TEMPLATE_KIND)"
    # a non-empty prior firmware search path, so the restore is exact (an empty prior
    # installs the inert sentinel, covered by the rollback suite)
    printf '/lib/firmware/vendor' > "$HALOW_FW_SYSFS_PATH"
    for f in morse.ko dot11ah.ko hostapd_s1g hostapd_cli_s1g hostapd_s1g.conf "${HALOW_FW_MAIN_NAME}" "bcf/${HALOW_FW_BCF_NAME}"; do
        echo "$(sha256sum "$HALOW_ARTIFACTS_DIR/$f" | awk '{print $1}')  ./$f"
    done > "$HALOW_ARTIFACTS_DIR/MANIFEST.sha256"

    # firewall fake (state in a temp directory)
    . "$TESTS_DIR/fakes/fw_helpers.sh"
    fw_fake_setup
    PATH="$B:$HALOW_TEST_TMP/fakebin:$PATH"
    export PATH

    # options
    export HALOW_OPT_REGION="AU" HALOW_OPT_BANDWIDTH="1" HALOW_OPT_WIFI_SSID="HaLow-Int" HALOW_OPT_WIFI_PASSPHRASE="integration-pass-1"
    export HALOW_OPT_HALOW_SUBNET_CIDR="192.168.90.1/24" HALOW_OPT_DHCP_RANGE_START="192.168.90.50" HALOW_OPT_DHCP_RANGE_END="192.168.90.150"
    export HALOW_OPT_UPLINK_INTERFACE="" HALOW_OPT_ALLOWED_PORTS=""

    # the radio facts the fakes report, taken from the real radio profile
    . "$HALOW_LIB_DIR/radio.sh"
    read -r CH KHZ < <(halow_radio_channels AU 1)
    local pw pi
    pw="$(_halow_radio_width_field AU 1 3)"; pi="$(_halow_radio_width_field AU 1 4)"
    printf 's1g_freq=%s\ns1g_bw=1\ns1g_prim_chwidth=%s\ns1g_prim_1mhz_chan_index=%s\nstate=ENABLED\n' "$KHZ" "$(( pw == 1 ? 2 : 1 ))" "$pi" > "$W/status"
    printf 'wlu1: ACS-COMPLETED freq=%s channel=%s\n' "$KHZ" "$CH" > "$W/acs_line"
}

# run_manager — starts the manager in its namespace; waits for operating or attention.
run_manager() {
    cat > "$W/child.sh" <<'CHILD'
set -o errexit -o errtrace -o nounset -o pipefail
shopt -s inherit_errexit
/usr/bin/mount --bind "$HALOW_SYS_MODULE_DIR" /sys/module
. "$HALOW_LIB_DIR/libs.sh"
halow_source_all_libs "$HALOW_LIB_DIR" || echo "MISSING LIBS: $HALOW_LIBS_MISSING" >&2
trap 'halow_manager_on_stop' TERM INT
halow_manager_main
CHILD
    unshare -rm bash "$W/child.sh" > "$W/manager.out" 2>&1 &
    MPID=$!
    # A deadline, not a fixed number of polls: under load a start can take long; the
    # loop ends as soon as the state is reached or the manager has gone.
    local deadline=$((SECONDS + ${HALOW_IT_START_LIMIT_S:-300}))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if [ -f "$HALOW_STATUS_FILE" ] && grep -q -E '"overall": *"(operating|attention)"' "$HALOW_STATUS_FILE"; then
            break
        fi
        kill -0 "$MPID" 2>/dev/null || break
        sleep 0.5
    done
}
stop_manager() {
    kill -TERM "$MPID" 2>/dev/null
    local deadline=$((SECONDS + ${HALOW_IT_STOP_LIMIT_S:-300}))
    while [ "$SECONDS" -lt "$deadline" ]; do kill -0 "$MPID" 2>/dev/null || break; sleep 0.5; done
    if wait "$MPID"; then MEXIT=0; else MEXIT=$?; fi
}
overall() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["overall"])' "$HALOW_STATUS_FILE" 2>/dev/null; }
jget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); exec("v="+sys.argv[2]); print(v)' "$HALOW_STATUS_FILE" "$1" 2>/dev/null; }
host_clean_checks() {
    assert_eq "" "$(halow_own_list | tr '\n' ' ')$(HALOW_STATE_DIR="$HALOW_RUN_DIR" halow_own_list | tr '\n' ' ')" "$1: no ownership marker remains"
    assert_eq "" "$(cat "$W/mods")" "$1: no module remains loaded"
    assert_failure "$1: the bridge is gone" test -d "$HALOW_SYS_CLASS_NET_DIR/halow-br0"
    assert_eq "0" "$( { fw iptables -S; fw iptables -t nat -S; fw ip6tables -S; } 2>/dev/null | grep -c -E -- '-N HALOW-(IN|FWD-OUT|FWD-IN|NAT)6?$' )" "$1: no add-on firewall chain remains"
    assert_eq "/lib/firmware/vendor" "$(cat "$HALOW_FW_SYSFS_PATH")" "$1: the firmware search path holds its prior value"
    assert_failure "$1: no hostapd_s1g process remains" pgrep -f "$HALOW_RUN_DIR/hostapd_s1g.conf"
    assert_failure "$1: no dnsmasq of this run remains" pgrep -f "$HALOW_RUN_DIR/dnsmasq"
    assert_eq "true" "$(cat "$W/nm7" 2>/dev/null || echo true)" "$1: the parent interface is managed again"
    assert_eq "0" "$(cat "$W/procsys/net/ipv6/conf/wlu1/disable_ipv6")" "$1: IPv6 on the parent is back to its recorded value"
    assert_success "$1: the run directory was mounted as a tmpfs and the ready file created" bash -c "grep -q 'mount -t tmpfs -o mode=0755,size=32m,nosuid,nodev,noexec tmpfs $HALOW_RUN_DIR' '$W/host.calls' && test -e '$HALOW_RUN_DIR/.ready'"
}

echo "-- manual mode: real libraries reach operating, then stop rolls everything back --"
world
export HALOW_OPT_RADIO_MODE="manual" HALOW_OPT_CHANNEL="$CH"
run_manager
assert_eq "operating" "$(overall)" "the status snapshot says operating"
if [ "$(overall)" != "operating" ]; then
    echo "    attention: $(jget 'd["attention"]')"
    tail -n 25 "$W/manager.out" | sed 's/^/    | /'
fi
assert_eq "manual" "$(jget 'd["radio"]["effective"]["source"]')" "effective source manual"
assert_eq "$CH" "$(jget 'd["radio"]["effective"]["channel"]')" "effective channel"
assert_eq "True" "$(jget 'd["backend"]["applied"]')" "backend applied"
assert_success "dot11ah was loaded with the region's scheme" grep -q 'insmod .*dot11ah.ko channelization_scheme=' "$W/host.calls"
assert_success "the firmware search path was set and restored around the morse load" grep -q 'mount -o remount,bind,ro /sys' "$W/host.calls"
assert_failure "the passphrase is not in the manager's output" grep -q 'integration-pass-1' "$W/manager.out"
assert_failure "the passphrase is not in the status snapshot" grep -q 'integration-pass-1' "$HALOW_STATUS_FILE"
assert_eq "1" "$(cat "$W/procsys/net/ipv6/conf/wlu1/disable_ipv6")" "IPv6 is off on the parent while operating"
assert_eq "1" "$(cat "$W/procsys/net/ipv6/conf/halow-br0/disable_ipv6")" "IPv6 is off on the bridge while operating"
assert_success "mac80211 brought libarc4 with it (the module set the rollback must undo)" grep -q '^libarc4 ' "$W/mods"
stop_manager
assert_eq "0" "$MEXIT" "exit 0 after a confirmed rollback"
host_clean_checks "manual"
halow_test_teardown

echo "-- automatic mode: selection completes, source acs --"
world
export HALOW_OPT_RADIO_MODE="automatic" HALOW_OPT_CHANNEL=""
run_manager
assert_eq "operating" "$(overall)" "operating"
assert_eq "acs" "$(jget 'd["radio"]["effective"]["source"]')" "effective source acs"
stop_manager
assert_eq "0" "$MEXIT" "exit 0"
host_clean_checks "automatic"
halow_test_teardown

echo "-- automatic mode: selection fails, the fallback channel runs with the advisory --"
world
export HALOW_OPT_RADIO_MODE="automatic" HALOW_OPT_CHANNEL=""
: > "$W/acs_fail"
FB="$(halow_radio_fallback_channel AU 1)"
FBKHZ="$(halow_radio_channels AU 1 | awk -v c="$FB" '$1==c {print $2}')"
sed -i "s/^s1g_freq=.*/s1g_freq=$FBKHZ/" "$W/status"
run_manager
assert_eq "operating" "$(overall)" "operating"
assert_eq "fallback" "$(jget 'd["radio"]["effective"]["source"]')" "effective source fallback"
assert_eq "RADIO_AUTO_FALLBACK" "$(jget 'd["advisory"]["code"]')" "the advisory is shown"
stop_manager
assert_eq "0" "$MEXIT" "exit 0 after a confirmed rollback"
if [ "$MEXIT" != "0" ]; then tail -n 25 "$W/manager.out" | sed 's/^/    | /'; fi
host_clean_checks "fallback"
halow_test_teardown

echo "-- kernel log ring full (each new record evicts an old one, the line count does not grow; observed on a long-running device): the start still reaches operating --"
world
export HALOW_OPT_RADIO_MODE="manual" HALOW_OPT_CHANNEL="$CH"
: > "$W/ring_full"
run_manager
assert_eq "operating" "$(overall)" "operating although the kernel log's line count did not grow during the load"
assert_eq "10" "$(wc -l < "$W/dmesg" | tr -d ' ')" "the fake log really kept the same line count (the old line-count watermark would have seen no new line)"
stop_manager
assert_eq "0" "$MEXIT" "exit 0 after a confirmed rollback"
host_clean_checks "ring-full"
halow_test_teardown

echo "-- the driver logs a board file with a different CRC-32 than the one placed: attention FIRMWARE_INVALID, rolled back --"
world
export HALOW_OPT_RADIO_MODE="manual" HALOW_OPT_CHANNEL="$CH"
printf '0xdeadbeef\n' > "$W/bcf.crc"
run_manager
assert_eq "attention" "$(overall)" "attention"
assert_eq "FIRMWARE_INVALID" "$(jget 'd["attention"]["code"]')" "FIRMWARE_INVALID"
assert_success "the detail names the mismatch" grep -q 'different board file than the one placed' "$HALOW_STATUS_FILE"
assert_eq "True" "$(jget 'd["attention"]["host_clean"]')" "host_clean true (the driver was unloaded again)"
assert_failure "no hostapd_s1g process was started" pgrep -f "$HALOW_RUN_DIR/hostapd_s1g.conf"
stop_manager
assert_eq "0" "$MEXIT" "exit 0"
host_clean_checks "bcf-crc-mismatch"
halow_test_teardown

echo "-- the kernel log is cleared during the morse load: the attempt's records cannot be proven, HOST_STATE_FAILED, rolled back --"
world
export HALOW_OPT_RADIO_MODE="manual" HALOW_OPT_CHANNEL="$CH"
: > "$W/wipe_log"
run_manager
assert_eq "attention" "$(overall)" "attention"
assert_eq "HOST_STATE_FAILED" "$(jget 'd["attention"]["code"]')" "HOST_STATE_FAILED"
assert_success "the detail says the records of this load could not be established" grep -q 'cannot establish the kernel-log records of this driver load' "$HALOW_STATUS_FILE"
assert_success "and names the concrete reason (the marker is no longer in the kernel log)" grep -q 'marker is no longer in the kernel log' "$HALOW_STATUS_FILE"
assert_eq "True" "$(jget 'd["attention"]["host_clean"]')" "host_clean true (the driver was unloaded again)"
assert_success "morse was loaded by the attempt (the failure came after the load)" grep -q '^insmod .*morse.ko' "$W/host.calls"
assert_failure "no hostapd_s1g process was started" pgrep -f "$HALOW_RUN_DIR/hostapd_s1g.conf"
stop_manager
assert_eq "0" "$MEXIT" "exit 0"
host_clean_checks "log-cleared-during-load"
halow_test_teardown

echo "-- a kernel log without any kernel timestamps: no marker can be taken before the load, HOST_STATE_FAILED with the reason, morse never loaded --"
world
export HALOW_OPT_RADIO_MODE="manual" HALOW_OPT_CHANNEL="$CH"
printf 'a record without a kernel timestamp\nanother one\n' > "$W/dmesg"
run_manager
assert_eq "attention" "$(overall)" "attention"
assert_eq "HOST_STATE_FAILED" "$(jget 'd["attention"]["code"]')" "HOST_STATE_FAILED"
assert_success "the detail names the concrete reason (no record has a kernel timestamp)" grep -q 'no record has a kernel timestamp' "$HALOW_STATUS_FILE"
assert_eq "True" "$(jget 'd["attention"]["host_clean"]')" "host_clean true"
assert_failure "morse was never loaded" grep -q '^insmod .*morse.ko' "$W/host.calls"
stop_manager
assert_eq "0" "$MEXIT" "exit 0"
host_clean_checks "no-kernel-timestamps"
halow_test_teardown

echo "-- no adapter: attention NO_ADAPTER, nothing changed on the host --"
world
export HALOW_OPT_RADIO_MODE="manual" HALOW_OPT_CHANNEL="$CH"
rm -f "$W/usb/1-1" "$W/usb/1-1:1.0"
run_manager
assert_eq "attention" "$(overall)" "attention"
assert_eq "NO_ADAPTER" "$(jget 'd["attention"]["code"]')" "NO_ADAPTER"
assert_eq "True" "$(jget 'd["attention"]["host_clean"]')" "host_clean true"
assert_failure "no module was loaded and /sys was not touched" grep -q -E '^(insmod|modprobe|rmmod|mount -o remount)' "$W/host.calls"
assert_success "only the run directory was mounted" grep -q '^mount -t tmpfs ' "$W/host.calls"
stop_manager
assert_eq "0" "$MEXIT" "exit 0"
halow_test_teardown

echo "-- a different host-module file (release, build string, banner, configuration and vermagic matching): UNSUPPORTED_KERNEL, nothing changed --"
world
export HALOW_OPT_RADIO_MODE="manual" HALOW_OPT_CHANNEL="$CH"
sed -i 's/official/officiaL/' "$HAT_GW_TREE/kernel/net/wireless/cfg80211.ko"
run_manager
assert_eq "attention" "$(overall)" "attention"
assert_eq "UNSUPPORTED_KERNEL" "$(jget 'd["attention"]["code"]')" "UNSUPPORTED_KERNEL"
assert_success "the detail names the module hash" grep -q 'host module cfg80211 SHA-256' "$HALOW_STATUS_FILE"
assert_eq "True" "$(jget 'd["attention"]["host_clean"]')" "host_clean true"
assert_failure "no module load, /sys remount, firewall, bridge or hostapd" grep -q -E '^(insmod|modprobe|rmmod|mount -o remount)' "$W/host.calls"
assert_eq "0" "$( { fw iptables -S; fw iptables -t nat -S; fw ip6tables -S; } 2>/dev/null | grep -c -E -- '-N HALOW-' )" "no add-on firewall chain was created"
assert_failure "no bridge was created" test -d "$HALOW_SYS_CLASS_NET_DIR/halow-br0"
assert_failure "no hostapd_s1g process was started" pgrep -f "$HALOW_RUN_DIR/hostapd_s1g.conf"
assert_eq "/lib/firmware/vendor" "$(cat "$HALOW_FW_SYSFS_PATH")" "the firmware search path is untouched"
assert_success "only the run directory was mounted" grep -q '^mount -t tmpfs ' "$W/host.calls"
stop_manager
assert_eq "0" "$MEXIT" "exit 0"
halow_test_teardown

echo "test_manager_integration: $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed"
exit $([ "$HALOW_TEST_FAILURES" -eq 0 ] && echo 0 || echo 1)
