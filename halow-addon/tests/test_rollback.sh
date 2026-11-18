#!/usr/bin/env bash
# rollback.sh: the documented order (backend -> station interfaces' NetworkManager marks ->
# hostapd -> bridge -> bridge and parent NetworkManager marks -> firewall filter chains ->
# modules -> firmware search path -> firmware files), idempotence, partial states, honest
# aggregate reporting (residual markers, host residue recognised by name, unowned
# processes), the hostapd lifecycle in the volatile run directory (and an earlier build's
# marker in the persistent one), and halow_finish_decide.
#
# The privileged libraries are the real ones (firmware placement, module unload, the
# firmware search path, NetworkManager restore, hostapd stop) over faked kernel/D-Bus
# commands; the bridge, firewall and backend are contract-level stubs.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh
. ./helpers_lifecycle.sh

echo "== test_rollback =="

# _wrap <function> — log "<function> <args>" to calls.log, then run the real function.
_wrap() {
    local fn="$1"
    eval "$(declare -f "$fn" | sed "1s/^$fn /_real_$fn /")"
    eval "$fn() { hl_log_call $fn \"\$@\"; _real_$fn \"\$@\"; }"
}

fresh() {
    local v lib
    for v in ${!HL_RC_*} ${!HL_RCSEQ_*}; do unset "$v"; done
    . ./helpers_lifecycle.sh
    hl_setup
    hl_child_load
    for lib in checksum firmware iface_detect module_load nm_unmanaged hostapd_config; do
        . "$HALOW_LIB_DIR/$lib.sh"
    done
    for v in halow_stop_hostapd halow_unload_modules halow_restore_firmware_search_path halow_remove_firmware halow_nm_restore_managed; do
        _wrap "$v"
    done
    MODS="$HL_DIR/lsmod"; : > "$MODS"
    lsmod() { echo "Module Size Used"; cat "$MODS"; }
    rmmod() {
        echo "rmmod $1" >> "$HL_DIR/calls.log"
        case " ${RMMOD_FAILS:-} " in *" $1 "*) return 1 ;; esac
        grep -v "^$1 " "$MODS" > "$MODS.tmp"; mv "$MODS.tmp" "$MODS"
    }
    halow_sys_mount_mode() { printf 'ro'; }
    halow_sysfs_write_with_remount() { printf '%s' "$2" > "$1"; }
    NM="$HL_DIR/nm"; mkdir -p "$NM"
    dbus-send() {
        local a dev="" val="" iface
        case "$*" in
            *GetDeviceByIpIface*)
                iface="${*: -1}"; iface="${iface#string:}"
                case "$iface" in
                    wlu1) echo '   object path "/org/freedesktop/NetworkManager/Devices/1"' ;;
                    halow-br0) echo '   object path "/org/freedesktop/NetworkManager/Devices/2"' ;;
                    wlu1.sta1) echo '   object path "/org/freedesktop/NetworkManager/Devices/3"' ;;
                    wlu1.sta2) echo '   object path "/org/freedesktop/NetworkManager/Devices/4"' ;;
                    *) return 1 ;;
                esac ;;
            *Properties.Get*)
                for a in "$@"; do case "$a" in /org/freedesktop/NetworkManager/Devices/*) dev="$a" ;; esac; done
                echo "   variant       boolean $(cat "$NM/${dev##*/}" 2>/dev/null || echo true)" ;;
            *Properties.Set*)
                for a in "$@"; do
                    case "$a" in
                        /org/freedesktop/NetworkManager/Devices/*) dev="$a" ;;
                        variant:boolean:*) val="${a#variant:boolean:}" ;;
                    esac
                done
                echo "$val" > "$NM/${dev##*/}"
                echo "nm-set ${dev##*/}=$val" >> "$HL_DIR/calls.log" ;;
            *) return 1 ;;
        esac
    }
    for i in wlu1 halow-br0 wlu1.sta1 wlu1.sta2; do mkdir -p "$HALOW_SYS_CLASS_NET_DIR/$i"; done
    # firmware artifacts and manifest in the real layout (bcf/ nested)
    printf 'main fw' > "$HALOW_ARTIFACTS_DIR/${HALOW_FW_MAIN_NAME}"
    mkdir -p "$HALOW_ARTIFACTS_DIR/bcf"
    printf 'bcf fw' > "$HALOW_ARTIFACTS_DIR/bcf/${HALOW_FW_BCF_NAME}"
    {
        echo "$(sha256sum "$HALOW_ARTIFACTS_DIR/${HALOW_FW_MAIN_NAME}" | awk '{print $1}')  ./${HALOW_FW_MAIN_NAME}"
        echo "$(sha256sum "$HALOW_ARTIFACTS_DIR/bcf/${HALOW_FW_BCF_NAME}" | awk '{print $1}')  ./bcf/${HALOW_FW_BCF_NAME}"
    } > "$HALOW_ARTIFACTS_DIR/MANIFEST.sha256"
}

# full_state — what a running manager has recorded and changed.
full_state() {
    halow_place_firmware "$HALOW_ARTIFACTS_DIR/${HALOW_FW_MAIN_NAME}" "${HALOW_FW_DIR}/${HALOW_FW_MAIN_NAME}" "$(halow_checksum_for "$HALOW_FW_MAIN_NAME")" firmware_main firmware_dir >/dev/null 2>&1
    halow_place_firmware "$HALOW_ARTIFACTS_DIR/bcf/${HALOW_FW_BCF_NAME}" "${HALOW_FW_DIR}/${HALOW_FW_BCF_NAME}" "$(halow_checksum_for "bcf/$HALOW_FW_BCF_NAME")" firmware_bcf firmware_dir >/dev/null 2>&1
    halow_own_mark fw_search_path "$(printf 'applied\n/prior/path\n/ours/halow_fw')"
    printf '/ours/halow_fw' > "$HALOW_FW_SYSFS_PATH"
    halow_nm_mark_unmanaged wlu1 nm_unmanaged_parent >/dev/null 2>&1
    halow_nm_mark_unmanaged halow-br0 nm_unmanaged_bridge >/dev/null 2>&1
    halow_nm_mark_unmanaged wlu1.sta1 nm_unmanaged_wds_wlu1.sta1 >/dev/null 2>&1
    halow_nm_mark_unmanaged wlu1.sta2 nm_unmanaged_wds_wlu1.sta2 >/dev/null 2>&1
    halow_own_mark module_dot11ah; echo "dot11ah 1 0" >> "$MODS"
    halow_own_mark module_morse; echo "morse 1 0" >> "$MODS"
    halow_own_mark net_bridge; halow_own_mark fw_filter
    halow_own_mark net_bridge_addr; halow_own_mark net_dnsmasq; halow_own_mark fw_nat
    # hostapd: marker and files in the run directory, the process already gone
    ( sleep 0.1 ) & local p=$!; wait "$p" 2>/dev/null || true
    mkdir -p "$HALOW_RUN_DIR"
    echo "$p" > "$HALOW_RUN_DIR/hostapd_s1g.pid"
    : > "$HALOW_RUN_DIR/hostapd_s1g.conf"; : > "$HALOW_RUN_DIR/hostapd_s1g.log"
    HALOW_STATE_DIR="$HALOW_RUN_DIR" halow_own_mark hostapd_process
    : > "$HL_DIR/calls.log"
}
rb() { if halow_rollback >"$HL_DIR/rb.out" 2>&1; then RB=0; else RB=$?; fi; }
line_of() { grep -n -E "$1" "$HL_DIR/calls.log" | head -n1 | cut -d: -f1; }
before() { local a b; a="$(line_of "$1")"; b="$(line_of "$2")"; [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; }

echo "-- from a complete running state: everything undone, in the documented order --"
fresh; full_state
rb
assert_eq "0" "$RB" "rollback returns 0"
assert_eq "" "$HALOW_ROLLBACK_RESIDUAL" "nothing residual"
assert_eq " " "$(hl_owned) " "no ownership marker remains (state and run directories)"
assert_file_absent "${HALOW_FW_DIR}/${HALOW_FW_MAIN_NAME}" "main firmware removed"
assert_file_absent "${HALOW_FW_DIR}/${HALOW_FW_BCF_NAME}" "board file removed"
assert_file_absent "$HALOW_FW_DIR" "the created firmware directory removed"
assert_eq "/prior/path" "$(cat "$HALOW_FW_SYSFS_PATH")" "firmware search path restored exactly"
for d in 1 2 3 4; do assert_eq "true" "$(cat "$NM/$d")" "NetworkManager device $d restored to managed"; done
assert_eq "" "$(cat "$MODS")" "both modules unloaded"
assert_file_absent "$HALOW_RUN_DIR/hostapd_s1g.conf" "the passphrase-bearing config in the run directory is removed"
assert_file_absent "$HALOW_RUN_DIR/hostapd_s1g.pid" "hostapd pid file removed"
assert_success "1 backend teardown before station NetworkManager restore" before '^fake_backend_teardown' '^halow_nm_restore_managed nm_unmanaged_wds'
assert_success "2 station restores before hostapd stop" before '^nm-set 4=true' '^halow_stop_hostapd'
assert_success "2 both station keys restored before hostapd stop" before '^nm-set 3=true' '^halow_stop_hostapd'
assert_success "3 hostapd stop before bridge delete" before '^halow_stop_hostapd' '^halow_bridge_delete halow-br0'
assert_success "4 bridge delete before the bridge NetworkManager restore" before '^halow_bridge_delete' '^nm-set 2=true'
assert_success "5 bridge restore before parent restore" before '^nm-set 2=true' '^nm-set 1=true'
assert_success "5 parent restore before the filter chains are removed" before '^nm-set 1=true' '^halow_fw_remove_filters'
assert_success "6 filter chains before the modules" before '^halow_fw_remove_filters' '^rmmod morse'
assert_success "7 morse before dot11ah" before '^rmmod morse' '^rmmod dot11ah'
assert_success "7 modules before the firmware search path" before '^rmmod dot11ah' '^halow_restore_firmware_search_path'
assert_success "8 search path before the firmware files" before '^halow_restore_firmware_search_path' '^halow_remove_firmware'
assert_success "every interface is restored before any module is unloaded" before '^nm-set 1=true' '^rmmod'
assert_success "complete is logged" grep -q 'rollback: complete' "$HL_DIR/rb.out"

echo "-- idempotent: a second call from the clean state is a no-op success --"
: > "$HL_DIR/calls.log"
rb
assert_eq "0" "$RB" "second rollback returns 0"
assert_failure "no module is touched again" grep -q '^rmmod' "$HL_DIR/calls.log"
assert_failure "no NetworkManager write again" grep -q '^nm-set' "$HL_DIR/calls.log"
halow_test_teardown

echo "-- partial state (stopped after the first module): only that is undone --"
fresh
halow_own_mark fw_filter
halow_own_mark module_dot11ah; echo "dot11ah 1 0" >> "$MODS"
: > "$HL_DIR/calls.log"
rb
assert_eq "0" "$RB" "returns 0"
assert_success "dot11ah unloaded" grep -q '^rmmod dot11ah' "$HL_DIR/calls.log"
assert_failure "morse (never loaded) not touched" grep -q '^rmmod morse' "$HL_DIR/calls.log"
assert_success "the filter chains removed" grep -q '^UNDO fw_filter' "$HL_DIR/calls.log"
assert_failure "the bridge (never created, not on the host) not touched" grep -q '^halow_bridge_delete' "$HL_DIR/calls.log"
halow_test_teardown

echo "-- an unloadable module: INCOMPLETE, exact residue, non-zero, marker kept --"
fresh; full_state
RMMOD_FAILS="morse"
rb
assert_eq "1" "$RB" "returns 1"
assert_success "the INCOMPLETE line names the exact residue" grep -q 'rollback: INCOMPLETE — residual ownership: \[module_morse\]' "$HL_DIR/rb.out"
assert_eq "module_morse" "$HALOW_ROLLBACK_RESIDUAL" "HALOW_ROLLBACK_RESIDUAL lists it"
assert_success "the marker is kept for the next retry" halow_own_check module_morse
assert_failure "every other step still ran (firmware removed)" test -e "${HALOW_FW_DIR}/${HALOW_FW_MAIN_NAME}"
halow_test_teardown

echo "-- an add-on module mac80211 that cannot be removed is reported too --"
fresh
halow_own_mark module_mac80211; echo "mac80211 1 0" >> "$MODS"
RMMOD_FAILS="mac80211"
rb
assert_eq "1" "$RB" "returns 1"
assert_success "module_mac80211 in the residue" grep -q 'module_mac80211' <<< "$HALOW_ROLLBACK_RESIDUAL"
halow_test_teardown

echo "-- host residue recognised by name: the bridge and the chains are verified gone from the host --"
fresh
HL_RC_halow_bridge_exists=0
HL_RC_halow_fw_present=0
rb
assert_eq "1" "$RB" "returns 1 while the host still shows them"
assert_success "the bridge is deleted by name although no marker was held" grep -q '^halow_bridge_delete halow-br0' "$HL_DIR/calls.log"
assert_success "the residue names the bridge" grep -q 'bridge:halow-br0' <<< "$HALOW_ROLLBACK_RESIDUAL"
assert_success "the residue names the chains" grep -q 'firewall-chains' <<< "$HALOW_ROLLBACK_RESIDUAL"
assert_success "reported as still present on the host" grep -q 'still present on the host' "$HL_DIR/rb.out"
halow_test_teardown

echo "-- a backend teardown hard failure (an unowned live process) is not representable as a key but still fails --"
fresh
HL_RC_fake_backend_teardown=1
rb
assert_eq "1" "$RB" "returns 1"
assert_success "reported" grep -q 'unowned-process' <<< "$HALOW_ROLLBACK_RESIDUAL"
halow_test_teardown

echo "-- no backend registered: the network side cannot be undone, never reported clean --"
fresh
HALOW_BACKEND_NAME=""
rb
assert_eq "1" "$RB" "returns 1"
halow_test_teardown

echo "-- hostapd identity cannot be confirmed: its marker (run directory) is kept and reported --"
fresh; full_state
halow_hostapd_determine_outcome() { HALOW_HOSTAPD_OUTCOME="unknown"; HALOW_HOSTAPD_TARGET_PID=""; }
rb
assert_eq "1" "$RB" "returns 1"
assert_success "hostapd_process is in the residue" grep -q 'hostapd_process' <<< "$HALOW_ROLLBACK_RESIDUAL"
assert_success "the marker is kept in the run directory" test -e "$HALOW_RUN_DIR/owns/hostapd_process"
halow_test_teardown

echo "-- a hostapd marker left in the persistent directory by an earlier build is still honoured --"
fresh
halow_own_mark hostapd_process
: > "$HALOW_STATE_DIR/hostapd_s1g.conf"
rb
assert_eq "0" "$RB" "returns 0"
assert_failure "the old marker is cleared" halow_own_check hostapd_process
assert_file_absent "$HALOW_STATE_DIR/hostapd_s1g.conf" "the old config file is removed"
halow_test_teardown

echo "-- the inert sentinel: complete, but reported as not an exact restoration --"
fresh
halow_own_mark fw_search_path "$(printf 'applied\n\n/ours/halow_fw')"
printf '/ours/halow_fw' > "$HALOW_FW_SYSFS_PATH"
rb
assert_eq "0" "$RB" "returns 0"
assert_eq "$HALOW_FW_SEARCH_SENTINEL" "$(cat "$HALOW_FW_SYSFS_PATH")" "the sentinel is installed"
assert_success "reboot-required marker set" halow_own_check firmware_path_reboot_required
assert_success "reported as NOT an exact restoration" grep -q 'NOT an exact restoration' "$HL_DIR/rb.out"
halow_test_teardown

echo "-- a foreign value on the firmware path is never overwritten --"
fresh
halow_own_mark fw_search_path "$(printf 'applied\n/prior\n/ours/halow_fw')"
printf '/someone/else' > "$HALOW_FW_SYSFS_PATH"
rb
assert_eq "1" "$RB" "returns 1"
assert_eq "/someone/else" "$(cat "$HALOW_FW_SYSFS_PATH")" "the foreign value is kept"
assert_success "fw_search_path in the residue" grep -q 'fw_search_path' <<< "$HALOW_ROLLBACK_RESIDUAL"
halow_test_teardown

echo "-- load intents: a module loaded by this add-on without its own record is recognised by the before/after comparison --"
RMMOD_FAILS=""
fresh
halow_own_mark module_intent_dot11ah "cfg80211"
halow_own_mark module_intent_morse "cfg80211 dot11ah"
printf 'cfg80211 1 0\ndot11ah 1 0\nmorse 1 0\nmac80211 1 0\nlibarc4 1 0\n' > "$MODS"
: > "$HL_DIR/calls.log"
rb
assert_eq "0" "$RB" "returns 0"
assert_eq "rmmod morse;rmmod mac80211;rmmod libarc4;rmmod dot11ah;" "$(grep '^rmmod' "$HL_DIR/calls.log" | tr '\n' ';')" "unloaded in dependency order: morse, mac80211, libarc4, then dot11ah"
assert_eq "cfg80211 1 0" "$(cat "$MODS")" "the module that was loaded before the intent is untouched"
assert_eq " " "$(hl_owned) " "the intents (and the records written for the unload) are cleared"
halow_test_teardown

fresh
halow_own_mark module_intent_morse "cfg80211 mac80211 libarc4"
halow_own_mark module_morse
printf 'cfg80211 1 0\nmac80211 1 0\nlibarc4 1 0\nmorse 1 0\n' > "$MODS"
: > "$HL_DIR/calls.log"
rb
assert_eq "0" "$RB" "returns 0"
assert_eq "rmmod morse;" "$(grep '^rmmod' "$HL_DIR/calls.log" | tr '\n' ';')" "mac80211 and libarc4, already loaded before the intent, are never unloaded"
assert_eq " " "$(hl_owned) " "intent cleared"
halow_test_teardown

fresh
halow_own_mark module_intent_morse "cfg80211"
printf 'cfg80211 1 0\nmac80211 1 0\nlibarc4 1 0\n' > "$MODS"
RMMOD_FAILS="libarc4"
rb
assert_eq "1" "$RB" "libarc4 that cannot be unloaded: returns 1"
assert_success "the residue names the dependency and keeps the intent" bash -c "grep -q 'module_libarc4' <<< '$HALOW_ROLLBACK_RESIDUAL' && grep -q 'module_intent_morse' <<< '$HALOW_ROLLBACK_RESIDUAL'"
assert_success "the intent is kept for the next retry" halow_own_check module_intent_morse
RMMOD_FAILS=""
halow_test_teardown

fresh
halow_own_mark module_intent_morse "cfg80211"
printf 'morse 1 0\n' > "$MODS"
lsmod() { return 1; }
rb
assert_eq "1" "$RB" "modules that cannot be listed: returns 1"
assert_success "the intent is kept" halow_own_check module_intent_morse
assert_success "...and reported" grep -q 'module_intent_morse' <<< "$HALOW_ROLLBACK_RESIDUAL"
halow_test_teardown

echo "-- IPv6 records: restored through the IPv6 library; an unconfirmed one is residue --"
fresh
halow_own_mark ipv6_wlu1 0
HL_UNDO_FAIL="ipv6_wlu1"
rb
assert_eq "1" "$RB" "returns 1"
assert_success "ipv6_wlu1 is in the residue" grep -q 'ipv6_wlu1' <<< "$HALOW_ROLLBACK_RESIDUAL"
assert_success "the restore was asked for" grep -q '^halow_ipv6_restore_all' "$HL_DIR/calls.log"
unset HL_UNDO_FAIL
rb
assert_eq "0" "$RB" "once restored: 0"
halow_test_teardown

echo "-- IPv6: a restore failure that no record accounts for is not reported complete --"
fresh
HL_RC_halow_ipv6_restore_all=1
rb
assert_eq "1" "$RB" "restore_all failed, nothing recorded, mount table readable: returns 1"
assert_success "...the residue names the switch mount" grep -q 'ipv6-switch-mount' <<< "$HALOW_ROLLBACK_RESIDUAL"
halow_test_teardown

echo "-- IPv6: an unreadable mount table with nothing recorded does not refuse forever --"
fresh
HL_RC_halow_ipv6_restore_all=1
HL_RC_halow_ipv6_mount_table_readable=1
rb
assert_eq "0" "$RB" "restore_all failed, nothing recorded, mount table unreadable: only logged, rollback completes"
assert_eq "" "$HALOW_ROLLBACK_RESIDUAL" "...with no residue"
halow_test_teardown

echo "-- IPv6: a held bracket record (a stuck temporary mount) is residual ownership --"
fresh
halow_own_mark ipv6br_wlu1 ro
HL_RC_halow_ipv6_restore_all=1
rb
assert_eq "1" "$RB" "a held bracket record: returns 1"
assert_success "ipv6br_wlu1 is in the residue" grep -q 'ipv6br_wlu1' <<< "$HALOW_ROLLBACK_RESIDUAL"
assert_failure "...and no extra switch-mount token (the record accounts for it)" grep -q 'ipv6-switch-mount' <<< "$HALOW_ROLLBACK_RESIDUAL"
unset HL_RC_halow_ipv6_restore_all
halow_own_clear ipv6br_wlu1
rb
assert_eq "0" "$RB" "once the record is gone: 0"
halow_test_teardown

fresh; full_state
rb
assert_success "IPv6 is restored after the NetworkManager marks and before the firewall chains and modules" before '^halow_ipv6_restore_all' '^rmmod'
halow_test_teardown

echo "-- the rollback does not depend on the caller's field separator (IFS='' as inside an interrupted read) --"
fresh; full_state
RMMOD_FAILS="morse"
_old_ifs="$IFS"; IFS=''
if halow_rollback >"$HL_DIR/rb.out" 2>&1; then RB=0; else RB=$?; fi
IFS="$_old_ifs"
assert_eq "1" "$RB" "an unconfirmed module is still reported with IFS=''"
assert_eq "module_morse" "$HALOW_ROLLBACK_RESIDUAL" "...naming exactly it"
halow_test_teardown

echo "-- halow_finish_decide (unchanged decision logic) --"
fresh
assert_success "clean: rollback ok, exit 0" halow_finish_decide 0 0
assert_success "clean: rollback ok, exit 256 (signal)" halow_finish_decide 0 256
assert_failure "halt: app failed" halow_finish_decide 0 7
assert_eq "7" "$(halow_finish_decide 0 7)" "the app's own code is preserved"
assert_failure "halt: rollback failed after a clean exit" halow_finish_decide 1 0
assert_eq "1" "$(halow_finish_decide 1 0)" "generic 1"
assert_failure "halt: rollback failed after a signal" halow_finish_decide 1 256
assert_eq "42" "$(halow_finish_decide 1 42)" "the app's code wins over the rollback's"
halow_test_teardown

echo "test_rollback: $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed"
exit $([ "$HALOW_TEST_FAILURES" -eq 0 ] && echo 0 || echo 1)
