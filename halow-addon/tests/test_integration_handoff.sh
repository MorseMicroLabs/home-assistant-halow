#!/usr/bin/env bash
# The hand-off between the manager and its finish hook, which s6 runs as SEPARATE
# processes sharing no shell state. The real `finish` script is run with a scrubbed
# environment (env -i) and no inherited shell functions; it must re-derive everything from
# the durable records and the host, roll back, keep the crash counter, persist the refusal
# when the rollback cannot be confirmed, and halt the container only past the bound.
#
# Hermetic: the finish process sources the real libraries of this subsystem and the real
# privileged libraries from a copy of the library directory, in which the libraries of the
# other subsystems are replaced by contract-level stand-ins (bridge, firewall, backend), and
# the kernel/D-Bus commands are fake programs on PATH.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh

echo "== test_integration_handoff =="
SVC_DIR="$(cd ../rootfs/etc/services.d/manager && pwd)"

echo "-- one library list: run and finish both use halow_source_all_libs --"
assert_success "run sources the libraries through halow_source_all_libs" grep -q '^if ! halow_source_all_libs' "$SVC_DIR/run"
assert_success "finish sources the libraries through halow_source_all_libs" grep -q '^if ! halow_source_all_libs' "$SVC_DIR/finish"
assert_failure "run keeps no library list of its own" grep -q 'for _lib in' "$SVC_DIR/run"
assert_failure "finish keeps no library list of its own" grep -q 'for _lib in' "$SVC_DIR/finish"
assert_success "finish calls the shared halow_finish_decide" grep -q 'halow_finish_decide' "$SVC_DIR/finish"
assert_success "finish registers the default backend" grep -q 'halow_backend_register_default' "$SVC_DIR/finish"
assert_success "run traps TERM and INT into the manager's stop handler" grep -q "^trap 'halow_manager_on_stop' TERM INT$" "$SVC_DIR/run"
assert_success "run starts halow_manager_main" grep -q '^halow_manager_main$' "$SVC_DIR/run"
. "$HALOW_LIB_DIR/libs.sh"
for lib in iface_detect hostapd_config nm_unmanaged module_load firmware checksum ownership backend ipv6 rollback lifecycle reconcile; do
    assert_success "the shared list contains $lib (needed by the finish-side rollback)" grep -q -w "$lib" <<< "$HALOW_LIBS_REQUIRED"
done
assert_failure "the old service directory is gone" test -d ../rootfs/etc/services.d/halow

setup_handoff() {
    halow_test_setup >/dev/null 2>&1 || true
    FAKE="$HALOW_TEST_TMP/fake"; mkdir -p "$FAKE/bin" "$FAKE/nm"
    LIBCOPY="$HALOW_TEST_TMP/lib"; mkdir -p "$LIBCOPY"
    local l
    for l in libs constants common checksum ownership validate firmware nm_unmanaged iface_detect module_load hostapd_config backend ipv6 bootid reconcile lifecycle options rollback manager; do
        cp "$HALOW_LIB_DIR/$l.sh" "$LIBCOPY/"
    done
    for l in state errors radio guard adapter dnsmasq stations allowlist uplink; do
        printf '#!/usr/bin/env bash\n# contract stand-in (test)\n' > "$LIBCOPY/$l.sh"
    done
    cat > "$LIBCOPY/bridge.sh" <<'EOF'
#!/usr/bin/env bash
halow_bridge_exists() { [ -e "$FAKE/bridge_$1" ]; }
halow_bridge_delete() { rm -f "$FAKE/bridge_$1"; [ -e "$FAKE/bridge_$1" ] && return 1; halow_own_clear net_bridge; echo "bridge-delete $1" >> "$FAKE/calls"; }
halow_bridge_create() { halow_own_mark net_bridge && : > "$FAKE/bridge_$1"; }
EOF
    cat > "$LIBCOPY/firewall.sh" <<'EOF'
#!/usr/bin/env bash
halow_fw_present() { [ -e "$FAKE/chains" ]; }
halow_fw_remove_filters() { rm -f "$FAKE/chains"; halow_own_clear fw_filter; echo "fw-remove-filters" >> "$FAKE/calls"; }
EOF
    cat > "$LIBCOPY/backend_bridge.sh" <<'EOF'
#!/usr/bin/env bash
bridge_backend_ownership_keys() { printf 'net_bridge_addr net_dnsmasq fw_nat'; }
bridge_backend_configure() { return 0; }
bridge_backend_attach() { return 0; }
bridge_backend_station_added() { return 0; }
bridge_backend_station_removed() { return 0; }
bridge_backend_teardown() { local k; for k in fw_nat net_dnsmasq net_bridge_addr; do halow_own_clear "$k"; done; echo "backend-teardown" >> "$FAKE/calls"; return 0; }
bridge_backend_health() { return 0; }
halow_backend_register_default() { halow_backend_register bridge; }
EOF
    cat > "$FAKE/bin/dbus-send" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *GetDeviceByIpIface*)
        iface="${*: -1}"; iface="${iface#string:}"
        [ -e "$FAKE/nm_down" ] && exit 1
        case "$iface" in
            wlu1) echo '   object path "/org/freedesktop/NetworkManager/Devices/1"' ;;
            halow-br0) echo '   object path "/org/freedesktop/NetworkManager/Devices/2"' ;;
            *) exit 1 ;;
        esac ;;
    *Properties.Get*)
        [ -e "$FAKE/nm_down" ] && exit 1
        for a in "$@"; do case "$a" in /org/freedesktop/NetworkManager/Devices/*) dev="$a" ;; esac; done
        echo "   variant       boolean $(cat "$FAKE/nm/${dev##*/}" 2>/dev/null || echo true)" ;;
    *Properties.Set*)
        [ -e "$FAKE/nm_down" ] && exit 1
        for a in "$@"; do
            case "$a" in
                /org/freedesktop/NetworkManager/Devices/*) dev="$a" ;;
                variant:boolean:*) val="${a#variant:boolean:}" ;;
            esac
        done
        echo "$val" > "$FAKE/nm/${dev##*/}" ;;
    *) exit 1 ;;
esac
EOF
    cat > "$FAKE/bin/lsmod" <<'EOF'
#!/usr/bin/env bash
echo "Module Size Used"; cat "$FAKE/mods" 2>/dev/null; exit 0
EOF
    cat > "$FAKE/bin/rmmod" <<'EOF'
#!/usr/bin/env bash
echo "rmmod $1" >> "$FAKE/calls"
[ -e "$FAKE/rmmod_fails" ] && exit 1
grep -v "^$1 " "$FAKE/mods" > "$FAKE/mods.tmp"; mv "$FAKE/mods.tmp" "$FAKE/mods"
EOF
    cat > "$FAKE/bin/halt" <<'EOF'
#!/usr/bin/env bash
echo halted > "$FAKE/halted"
exit 0
EOF
    chmod +x "$FAKE/bin/"*
    # the IPv6 switches are written through a temporary bind mount: the fake mount layer
    . ./doubles/fakes_env.sh; halow_fakes_mnt_install
    cp "$HALOW_FAKES_SRC/mount" "$HALOW_FAKES_SRC/umount" "$HALOW_FAKES_SRC/_mntlib.sh" "$FAKE/bin/"; chmod +x "$FAKE/bin/"*
    : > "$FAKE/mods"; : > "$FAKE/calls"
    printf 'sysfs /sys sysfs ro 0 0\n' > "$FAKE/mounts"
    PROCSYS="$HALOW_TEST_TMP/procsys"; mkdir -p "$PROCSYS/net/ipv6/conf/wlu1" "$PROCSYS/net/ipv6/conf/halow-br0"
    printf '1\n' > "$PROCSYS/net/ipv6/conf/wlu1/disable_ipv6"; printf '1\n' > "$PROCSYS/net/ipv6/conf/halow-br0/disable_ipv6"
    for i in wlu1 halow-br0; do mkdir -p "$HALOW_SYS_CLASS_NET_DIR/$i"; done
    printf 'main fw' > "$HALOW_ARTIFACTS_DIR/${HALOW_FW_MAIN_NAME}"
    printf 'bcf fw' > "$HALOW_ARTIFACTS_DIR/bcf/${HALOW_FW_BCF_NAME}"
    {
        echo "$(sha256sum "$HALOW_ARTIFACTS_DIR/${HALOW_FW_MAIN_NAME}" | awk '{print $1}')  ./${HALOW_FW_MAIN_NAME}"
        echo "$(sha256sum "$HALOW_ARTIFACTS_DIR/bcf/${HALOW_FW_BCF_NAME}" | awk '{print $1}')  ./bcf/${HALOW_FW_BCF_NAME}"
    } > "$HALOW_ARTIFACTS_DIR/MANIFEST.sha256"
    export FAKE
    PATH_SAVED="$PATH"; PATH="$FAKE/bin:$PATH"
}

# the run side: what a manager that crashed while operating leaves behind
run_side() {
    halow_place_firmware "$HALOW_ARTIFACTS_DIR/${HALOW_FW_MAIN_NAME}" "${HALOW_FW_DIR}/${HALOW_FW_MAIN_NAME}" "$(halow_checksum_for "$HALOW_FW_MAIN_NAME")" firmware_main firmware_dir >/dev/null 2>&1
    halow_place_firmware "$HALOW_ARTIFACTS_DIR/bcf/${HALOW_FW_BCF_NAME}" "${HALOW_FW_DIR}/${HALOW_FW_BCF_NAME}" "$(halow_checksum_for "bcf/$HALOW_FW_BCF_NAME")" firmware_bcf firmware_dir >/dev/null 2>&1
    halow_nm_mark_unmanaged wlu1 nm_unmanaged_parent >/dev/null 2>&1
    halow_nm_mark_unmanaged halow-br0 nm_unmanaged_bridge >/dev/null 2>&1
    halow_own_mark module_dot11ah; halow_own_mark module_morse
    printf 'dot11ah 1 0\nmorse 1 0\n' > "$FAKE/mods"
    halow_own_mark net_bridge; : > "$FAKE/bridge_halow-br0"
    halow_own_mark fw_filter; : > "$FAKE/chains"
    halow_own_mark net_bridge_addr; halow_own_mark net_dnsmasq; halow_own_mark fw_nat
    # IPv6 turned off on both interfaces (recorded originals 0)
    halow_own_mark ipv6_wlu1 0; halow_own_mark ipv6_halow-br0 0
    # the crash came between mac80211 being loaded (with libarc4) and its own record: only
    # the load intent, which lists the modules present before, shows they are this add-on's
    halow_own_mark module_intent_morse "cfg80211 dot11ah"; halow_own_mark module_intent_dot11ah "cfg80211"
    printf 'mac80211 1 0\nlibarc4 1 0\ncfg80211 1 0\n' >> "$FAKE/mods"
    ( sleep 0.1 ) & local p=$!; wait "$p" 2>/dev/null || true
    mkdir -p "$HALOW_RUN_DIR"
    echo "$p" > "$HALOW_RUN_DIR/hostapd_s1g.pid"
    printf 'wpa_passphrase=secret\n' > "$HALOW_RUN_DIR/hostapd_s1g.conf"
    : > "$HALOW_RUN_DIR/hostapd_s1g.log"
    HALOW_STATE_DIR="$HALOW_RUN_DIR" halow_own_mark hostapd_process
}

# finish_side <exit code> [<signal>] — the real finish script, a separate process, sourced
# under the strict shell options the base image's interpreter sets.
finish_side() {
    env -i \
        PATH="$PATH" FAKE="$FAKE" \
        HALOW_FAKE_MNT_DIR="$HALOW_FAKE_MNT_DIR" HALOW_PROC_MOUNTINFO="$HALOW_PROC_MOUNTINFO" \
        HALOW_LIB_DIR="$LIBCOPY" \
        HALOW_STATE_DIR="$HALOW_STATE_DIR" HALOW_RUN_DIR="$HALOW_RUN_DIR" \
        HALOW_FW_DIR="$HALOW_FW_DIR" HALOW_ARTIFACTS_DIR="$HALOW_ARTIFACTS_DIR" \
        HALOW_FW_SYSFS_PATH="$HALOW_FW_SYSFS_PATH" HALOW_PROC_MOUNTS="$FAKE/mounts" HALOW_PROC_SYS_DIR="$PROCSYS" \
        HALOW_SYS_CLASS_NET_DIR="$HALOW_SYS_CLASS_NET_DIR" HALOW_SYS_MODULE_DIR="$HALOW_SYS_MODULE_DIR" \
        HALOW_S6_RESULTS_FILE="$FAKE/exitcode" HALOW_S6_HALT="$FAKE/bin/halt" \
        bash -c 'set -o errexit -o errtrace -o nounset -o pipefail; shopt -s inherit_errexit; . "$0" "$@"' "$SVC_DIR/finish" "$@" > "$FAKE/finish.out" 2>&1
    FIN=$?
}

echo "-- a crashed manager: the separate finish process rolls everything back and lets s6 restart it --"
setup_handoff
run_side
assert_eq "false" "$(cat "$FAKE/nm/1")" "sanity: the parent is unmanaged after the run side"
assert_file_exists "$HALOW_RUN_DIR/hostapd_s1g.conf" "sanity: the passphrase-bearing config exists in the run directory"
finish_side 1
assert_eq "0" "$FIN" "finish exits 0 (below the bound: s6 restarts the manager)"
assert_eq " " "$(halow_own_list | tr '\n' ' ') $(HALOW_STATE_DIR="$HALOW_RUN_DIR" halow_own_list | tr '\n' ' ')" "every marker written by the run side was cleared by the finish process"
assert_file_absent "${HALOW_FW_DIR}/${HALOW_FW_MAIN_NAME}" "firmware removed"
assert_eq "true" "$(cat "$FAKE/nm/1")" "parent restored to managed"
assert_eq "true" "$(cat "$FAKE/nm/2")" "bridge restored to managed"
assert_eq "cfg80211 1 0" "$(cat "$FAKE/mods")" "modules unloaded: the recorded ones, and mac80211 and libarc4 which only the load intent shows the add-on loaded; cfg80211 (loaded before) untouched"
assert_eq "0" "$(cat "$PROCSYS/net/ipv6/conf/wlu1/disable_ipv6")" "the parent's IPv6 setting is restored"
assert_eq "0" "$(cat "$PROCSYS/net/ipv6/conf/halow-br0/disable_ipv6")" "the bridge's IPv6 setting is restored"
assert_file_absent "$FAKE/bridge_halow-br0" "bridge deleted"
assert_file_absent "$FAKE/chains" "filter chains removed"
assert_success "backend teardown ran" grep -q backend-teardown "$FAKE/calls"
assert_file_absent "$HALOW_RUN_DIR/hostapd_s1g.conf" "the passphrase-bearing config is removed"
assert_eq "1" "$(cat "$HALOW_RUN_DIR/manager_exits" | wc -l | tr -d ' ')" "the exit is counted in the run directory"
assert_file_absent "$FAKE/halted" "not halted"
assert_failure "no refusal (rollback confirmed)" test -e "$HALOW_STATE_DIR/refusal"
assert_failure "the passphrase never appears in the finish output" grep -q secret "$FAKE/finish.out"

echo "-- a clean stop (exit 0) resets the counter --"
finish_side 0
assert_eq "0" "$FIN" "exit 0"
assert_file_absent "$HALOW_RUN_DIR/manager_exits" "the counter is reset"
PATH="$PATH_SAVED"; halow_test_teardown

echo "-- a rollback the finish process cannot confirm persists the refusal --"
setup_handoff
run_side
: > "$FAKE/rmmod_fails"
finish_side 1
assert_eq "0" "$FIN" "finish exits 0 below the bound (the manager restarts and retries only rollback)"
assert_success "the refusal is persisted" test -e "$HALOW_STATE_DIR/refusal"
assert_success "INCOMPLETE is logged with the module markers (and the ones only the load intent recognised)" grep -q 'residual ownership: \[module_dot11ah module_mac80211 module_morse module_libarc4 module_intent_morse module_intent_dot11ah\]' "$FAKE/finish.out"
assert_success "the module markers are kept" halow_own_check module_morse
echo "   ... a clean exit with an unconfirmed rollback is still counted, never reported clean"
finish_side 0
assert_success "counted" test "$(wc -l < "$HALOW_RUN_DIR/manager_exits" | tr -d ' ')" -eq 2
assert_failure "not reported as finished cleanly" grep -q 'finished cleanly' "$FAKE/finish.out"
PATH="$PATH_SAVED"; halow_test_teardown

echo "-- crash-loop bound: the fifth exit within the window halts the container with the exit code --"
setup_handoff
for n in 1 2 3 4; do
    finish_side 3
    assert_file_absent "$FAKE/halted" "exit $n: not halted"
done
finish_side 3
assert_success "the fifth exit halts" test -e "$FAKE/halted"
assert_eq "3" "$(cat "$FAKE/exitcode")" "the manager's exit code is written to the results file"
PATH="$PATH_SAVED"; halow_test_teardown

echo "-- old exits outside the window do not count --"
setup_handoff
mkdir -p "$HALOW_RUN_DIR"
printf '1\n2\n3\n4\n' > "$HALOW_RUN_DIR/manager_exits"
finish_side 3
assert_file_absent "$FAKE/halted" "four ancient exits plus one now: not halted"
PATH="$PATH_SAVED"; halow_test_teardown

echo "-- a signal death (256) with a confirmed rollback is counted; halt code 1 at the bound --"
setup_handoff
for n in 1 2 3 4 5; do finish_side 256 9; done
assert_success "halted after five" test -e "$FAKE/halted"
assert_eq "1" "$(cat "$FAKE/exitcode")" "generic code 1"
PATH="$PATH_SAVED"; halow_test_teardown

echo "-- the finish side needs iface_detect: D-Bus unreachable but the interface still present keeps ownership --"
setup_handoff
halow_nm_mark_unmanaged wlu1 nm_unmanaged_parent >/dev/null 2>&1
: > "$FAKE/nm_down"
finish_side 1
assert_success "nm_unmanaged_parent is kept (not silently cleared on a D-Bus failure)" halow_own_check nm_unmanaged_parent
assert_success "...and reported" grep -q 'residual ownership: \[nm_unmanaged_parent\]' "$FAKE/finish.out"
assert_failure "no 'command not found' in the finish process" grep -q 'command not found' "$FAKE/finish.out"
PATH="$PATH_SAVED"; halow_test_teardown

echo "test_integration_handoff: $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed"
exit $([ "$HALOW_TEST_FAILURES" -eq 0 ] && echo 0 || echo 1)
