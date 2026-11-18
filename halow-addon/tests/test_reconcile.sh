#!/usr/bin/env bash
# bootid.sh and reconcile.sh: boot id handling, the persisted refusal, stale-marker
# clearing after a reboot (with the automatic byte-exact firmware-path verification),
# residue recognised from the host with no markers, foreign state left alone, and an
# incomplete rollback.
#
# The real module-load and firmware-path code is used (with lsmod/rmmod and the /sys
# write faked), so module handling is checked against a fake kernel module list.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh
. ./helpers_lifecycle.sh

echo "== test_reconcile =="

BOOT_A="aaaaaaaa-0000-0000-0000-000000000001"
BOOT_B="bbbbbbbb-0000-0000-0000-000000000002"

fresh() {
    local v
    for v in ${!HL_RC_*} ${!HL_RCSEQ_*}; do unset "$v"; done
    . ./helpers_lifecycle.sh
    hl_setup
    hl_child_load
    # Real module and firmware-path handling over a fake module list and a plain file node.
    . "$HALOW_LIB_DIR/module_load.sh"
    MODS="$HL_DIR/lsmod"
    : > "$MODS"
    lsmod() { echo "Module Size Used"; cat "$MODS"; }
    rmmod() {
        echo "rmmod $1" >> "$HL_DIR/calls.log"
        [ -n "${RMMOD_FAILS:-}" ] && return 1
        grep -v "^$1 " "$MODS" > "$MODS.tmp"; mv "$MODS.tmp" "$MODS"
    }
    halow_sys_mount_mode() { printf 'ro'; }
    halow_sysfs_write_with_remount() { printf '%s' "$2" > "$1"; }
    printf '%s\n' "$BOOT_A" > "$HALOW_BOOT_ID_FILE"
    : > "$HALOW_FW_SYSFS_PATH"
}
loaded() { echo "$1 1000 0" >> "$MODS"; }
reconcile_rc() { if halow_reconcile >"$HL_DIR/rec.out" 2>&1; then REC_RC=0; else REC_RC=$?; fi; }

echo "-- boot id: current, recorded, changed --"
fresh
assert_eq "$BOOT_A" "$(halow_boot_id_current)" "current boot id read from the kernel file"
assert_exit 2 "nothing recorded yet: 2" halow_boot_id_changed
assert_success "record" halow_boot_id_record
assert_eq "$BOOT_A" "$(halow_boot_id_recorded)" "recorded value"
assert_file_exists "$HALOW_STATE_DIR/boot_id" "kept in the persistent state directory"
assert_exit 1 "same boot: 1" halow_boot_id_changed
printf '%s\n' "$BOOT_B" > "$HALOW_BOOT_ID_FILE"
assert_exit 0 "rebooted: 0" halow_boot_id_changed
rm -f "$HALOW_BOOT_ID_FILE"
assert_exit 3 "unreadable current id: 3" halow_boot_id_changed
assert_failure "record fails when the current id cannot be read" halow_boot_id_record
printf 'not a uuid!\n' > "$HALOW_BOOT_ID_FILE"
assert_failure "a malformed id is rejected" halow_boot_id_current
halow_test_teardown

echo "-- refusal: persisted, readable, cleared --"
fresh
assert_failure "absent at first" halow_refusal_present
assert_success "set" halow_refusal_set ROLLBACK_INCOMPLETE
assert_success "present" halow_refusal_present
assert_file_exists "$HALOW_STATE_DIR/refusal" "persisted in the state directory (survives a container restart)"
assert_eq "ROLLBACK_INCOMPLETE" "$(halow_refusal_reason)" "reason recorded"
assert_success "clear" halow_refusal_clear
assert_failure "absent after clear" halow_refusal_present
halow_test_teardown

echo "-- clean host, first start: 0, boot id recorded --"
fresh
reconcile_rc; assert_eq "0" "$REC_RC" "a clean host reconciles to 0"
assert_eq "$BOOT_A" "$(halow_boot_id_recorded)" "the boot id is recorded"
assert_success "no host change was made" hl_no_mutation
halow_test_teardown

echo "-- boot id changed: stale runtime markers cleared after checking the host; reboot-required verified --"
fresh
halow_boot_id_record
for k in module_morse module_dot11ah net_bridge fw_filter fw_nat; do halow_own_mark "$k"; done
halow_own_mark fw_search_path "$(printf 'applied\n\n/mnt/data/supervisor/apps/data/local_morse_micro_halow_ap/halow_fw')"
halow_own_mark firmware_path_reboot_required
printf '%s\n' "$BOOT_B" > "$HALOW_BOOT_ID_FILE"
printf '\n' > "$HALOW_FW_SYSFS_PATH"
reconcile_rc; assert_eq "0" "$REC_RC" "reconcile succeeds after the reboot"
for k in module_morse module_dot11ah net_bridge fw_filter fw_nat fw_search_path; do
    assert_failure "stale marker $k cleared" halow_own_check "$k"
done
assert_failure "the reboot-required marker is cleared after the byte-exact verification passed" halow_own_check firmware_path_reboot_required
assert_failure "no rmmod for modules the reboot already unloaded" grep -q '^rmmod' "$HL_DIR/calls.log"
assert_eq "$BOOT_B" "$(halow_boot_id_recorded)" "the new boot id is recorded"
assert_success "the reboot is noted" grep -q 'the host rebooted' <<< "$HALOW_RECONCILE_NOTES"
halow_test_teardown

echo "-- boot id changed, node not exactly empty: the reboot-required marker is kept --"
fresh
halow_boot_id_record
halow_own_mark firmware_path_reboot_required
printf '%s\n' "$BOOT_B" > "$HALOW_BOOT_ID_FILE"
printf '/run/halow-firmware-search-disabled' > "$HALOW_FW_SYSFS_PATH"
reconcile_rc
assert_success "kept (verification failed)" halow_own_check firmware_path_reboot_required
halow_test_teardown

echo "-- boot id changed, a radio module is loaded again by something else: marker cleared, module never unloaded --"
fresh
halow_boot_id_record
halow_own_mark module_morse
loaded morse
printf '%s\n' "$BOOT_B" > "$HALOW_BOOT_ID_FILE"
reconcile_rc; assert_eq "0" "$REC_RC" "reconcile 0"
assert_failure "the stale marker is cleared" halow_own_check module_morse
assert_failure "the module was never removed" grep -q '^rmmod morse' "$HL_DIR/calls.log"
assert_success "still loaded" grep -q '^morse ' "$MODS"
assert_success "reported as foreign" grep -q 'module:morse' <<< "$HALOW_RECONCILE_FOREIGN"
halow_test_teardown

echo "-- same boot: a module recorded as loaded by this add-on is unloaded by rollback --"
fresh
halow_boot_id_record
halow_own_mark module_morse
loaded morse
reconcile_rc; assert_eq "0" "$REC_RC" "reconcile 0"
assert_success "rmmod morse" grep -q '^rmmod morse' "$HL_DIR/calls.log"
assert_failure "gone" grep -q '^morse ' "$MODS"
assert_failure "marker cleared after confirmation" halow_own_check module_morse
halow_test_teardown

echo "-- residue recognised from the host with no markers (chains, bridge, processes, sentinel) --"
fresh
halow_boot_id_record
HL_RCSEQ_halow_fw_present="0 1"
HL_RCSEQ_halow_bridge_exists="0 0 1"
printf '/run/halow-firmware-search-disabled' > "$HALOW_FW_SYSFS_PATH"
reconcile_rc; assert_eq "0" "$REC_RC" "the residue is undone and verified"
assert_success "the firewall chains are removed although no marker was held" hl_called halow_fw_remove_filters
assert_success "the bridge is deleted by name although no marker was held" grep -q '^halow_bridge_delete halow-br0$' "$HL_DIR/calls.log"
assert_success "hostapd's identity scan runs (from the run directory scope)" hl_called halow_stop_hostapd
assert_success "the backend teardown (dnsmasq, NAT) runs" hl_called fake_backend_teardown
assert_success "the unrecorded sentinel is recognised: reboot-required state re-recorded" halow_own_check firmware_path_reboot_required
assert_success "no host change" hl_no_mutation
halow_test_teardown

echo "-- this add-on's directory on the firmware path with no record: not confirmable --"
fresh
halow_boot_id_record
printf '/mnt/data/supervisor/apps/data/local_morse_micro_halow_ap/halow_fw' > "$HALOW_FW_SYSFS_PATH"
reconcile_rc; assert_eq "1" "$REC_RC" "reconcile 1"
assert_success "named in the residue" grep -q 'fw_search_path:unrecorded' <<< "$HALOW_RECONCILE_RESIDUAL"
assert_eq "/mnt/data/supervisor/apps/data/local_morse_micro_halow_ap/halow_fw" "$(cat "$HALOW_FW_SYSFS_PATH")" "the node is not touched"
halow_test_teardown

echo "-- unrecognised foreign state is left alone and reported --"
fresh
halow_boot_id_record
loaded morse
HL_RCSEQ_halow_bridge_exists="1"
printf '/lib/firmware/vendor-x' > "$HALOW_FW_SYSFS_PATH"
reconcile_rc; assert_eq "0" "$REC_RC" "reconcile 0 (nothing of this add-on's is present)"
assert_success "a radio module loaded without a record is reported" grep -q 'module:morse' <<< "$HALOW_RECONCILE_FOREIGN"
assert_failure "...and never unloaded" grep -q '^rmmod' "$HL_DIR/calls.log"
assert_eq "/lib/firmware/vendor-x" "$(cat "$HALOW_FW_SYSFS_PATH")" "a foreign firmware path value is not touched"
assert_failure "no reboot-required state invented for a foreign value" halow_own_check firmware_path_reboot_required
assert_failure "only this add-on's bridge name is ever deleted" grep -q '^halow_bridge_delete' "$HL_DIR/calls.log"
halow_test_teardown

echo "-- incomplete rollback: 1, the residue named, the refusal kept; no new host change --"
fresh
halow_boot_id_record
halow_own_mark module_morse
loaded morse
RMMOD_FAILS=1
halow_refusal_set ROLLBACK_INCOMPLETE >/dev/null 2>&1
reconcile_rc; assert_eq "1" "$REC_RC" "reconcile 1"
assert_success "the residue names the module marker" grep -q 'module_morse' <<< "$HALOW_RECONCILE_RESIDUAL"
assert_success "the refusal stays" halow_refusal_present
assert_success "the marker stays (never cleared on a guess)" halow_own_check module_morse
assert_success "nothing but rollback was attempted" hl_no_mutation
echo "   ... the next retry succeeds once the module can be unloaded"
unset RMMOD_FAILS
reconcile_rc; assert_eq "0" "$REC_RC" "reconcile 0"
assert_failure "the refusal is cleared only now" halow_refusal_present
halow_test_teardown

echo "-- same boot, the manager died between loading morse and recording it: the load intent makes it this add-on's; the next start is not blocked --"
fresh
halow_boot_id_record
halow_own_mark module_intent_morse "cfg80211"
loaded cfg80211; loaded morse
reconcile_rc; assert_eq "0" "$REC_RC" "reconcile 0 (host verified clean)"
assert_success "morse was unloaded" grep -q '^rmmod morse' "$HL_DIR/calls.log"
assert_failure "cfg80211, loaded before the intent, was not" grep -q '^rmmod cfg80211' "$HL_DIR/calls.log"
assert_failure "morse is not reported as foreign" grep -q 'module:morse' <<< "$HALOW_RECONCILE_FOREIGN"
assert_failure "the intent is cleared" halow_own_check module_intent_morse
halow_test_teardown

echo "-- control: the same module with no intent is foreign and left alone --"
fresh
halow_boot_id_record
loaded morse
reconcile_rc; assert_eq "0" "$REC_RC" "reconcile 0"
assert_failure "not unloaded" grep -q '^rmmod morse' "$HL_DIR/calls.log"
assert_success "reported as foreign" grep -q 'module:morse' <<< "$HALOW_RECONCILE_FOREIGN"
halow_test_teardown

echo "-- boot id changed: load intents and IPv6 records describe the previous boot and are cleared; a module loaded now is foreign --"
fresh
halow_boot_id_record
halow_own_mark module_intent_morse "cfg80211"; halow_own_mark module_intent_dot11ah ""
halow_own_mark ipv6_wlu1 0
loaded morse
printf '%s\n' "$BOOT_B" > "$HALOW_BOOT_ID_FILE"
reconcile_rc; assert_eq "0" "$REC_RC" "reconcile 0"
assert_failure "intent morse cleared" halow_own_check module_intent_morse
assert_failure "intent dot11ah cleared" halow_own_check module_intent_dot11ah
assert_failure "the IPv6 record cleared" halow_own_check ipv6_wlu1
assert_failure "the temporary-mount bracket record cleared (a mount cannot outlive the reboot; the mount table is still checked by the rollback)" halow_own_check ipv6br_wlu1
assert_failure "the recorded IPv6 value was not written back over a post-reboot interface (dropped, not restored)" grep -q '^UNDO ipv6_wlu1$' "$HL_DIR/calls.log"
assert_failure "morse (loaded after the reboot) is not unloaded" grep -q '^rmmod morse' "$HL_DIR/calls.log"
assert_success "morse reported as foreign" grep -q 'module:morse' <<< "$HALOW_RECONCILE_FOREIGN"
halow_test_teardown

echo "-- IPv6 records on the same boot are restored through rollback --"
fresh
halow_boot_id_record
halow_own_mark ipv6_wlu1 0
reconcile_rc; assert_eq "0" "$REC_RC" "reconcile 0"
assert_success "noted" grep -q 'IPv6 settings changed by this add-on are recorded' <<< "$HALOW_RECONCILE_NOTES"
assert_success "restored" grep -q '^UNDO ipv6_wlu1$' "$HL_DIR/calls.log"
halow_test_teardown
fresh
halow_boot_id_record
halow_own_mark ipv6_wlu1 0
HL_UNDO_FAIL="ipv6_wlu1"
reconcile_rc; assert_eq "1" "$REC_RC" "an IPv6 setting that cannot be restored: reconcile 1"
assert_success "named in the residue" grep -q 'ipv6_wlu1' <<< "$HALOW_RECONCILE_RESIDUAL"
unset HL_UNDO_FAIL
halow_test_teardown

echo "-- unreadable boot id: markers are not treated as stale --"
fresh
halow_boot_id_record
halow_own_mark module_morse
loaded morse
rm -f "$HALOW_BOOT_ID_FILE"
reconcile_rc
assert_success "the module was unloaded through rollback (marker honoured, not dropped)" grep -q '^rmmod morse' "$HL_DIR/calls.log"
assert_eq "$BOOT_A" "$(halow_boot_id_recorded)" "the recorded id is not overwritten"
halow_test_teardown

echo "-- INPUT base chain created by this add-on (real firewall code over the fake iptables/nft) --"
# fresh_fw <present4:yes|no> <present6:yes|no> — `fresh`, then the real firewall functions
# (the lifecycle helpers stub them) over a Docker-like fake host whose INPUT base chain
# exists or does not exist yet.
fresh_fw() {
    local n
    fresh
    . ./fakes/fw_helpers.sh
    fw_fake_setup
    for n in iptables ip6tables; do
        fw "$n" -N DOCKER-USER
        fw "$n" -A DOCKER-USER -j RETURN
        fw "$n" -A FORWARD -j DOCKER-USER
    done
    [ "$1" = "no" ] && fw_base_absent iptables INPUT
    [ "$2" = "no" ] && fw_base_absent ip6tables INPUT
    . "$HALOW_LIB_DIR/validate.sh"
    . "$HALOW_LIB_DIR/allowlist.sh"
    . "$HALOW_LIB_DIR/uplink.sh"
    . "$HALOW_LIB_DIR/firewall.sh"
    fw_log_reset
}
fw_install() { halow_fw_install_filters halow-br0 192.168.90.1/24 192.168.90.1 eth0 "" >/dev/null 2>&1; }

echo "   same boot, the process died after the install: reconcile's rollback removes the chains and the base chain it created"
fresh_fw no no
fw_install
assert_success "the add-on created both INPUT base chains" test -e "$HALOW_STATE_DIR/owns/fw_created_input4" -a -e "$HALOW_STATE_DIR/owns/fw_created_input6"
halow_boot_id_record
reconcile_rc; assert_eq "0" "$REC_RC" "reconcile 0"
assert_failure "the IPv4 INPUT base chain is gone" fw_base_present iptables INPUT
assert_failure "the IPv6 INPUT base chain is gone" fw_base_present ip6tables INPUT
assert_failure "records cleared (IPv4)" halow_own_check fw_created_input4
assert_failure "records cleared (IPv6)" halow_own_check fw_created_input6
assert_failure "nothing of the add-on is left" halow_fw_present
halow_test_teardown

echo "   same boot, the process died between the record and the creation: the record is cleared, nothing is deleted"
fresh_fw no no
halow_own_mark fw_created_input4 "table=filter chain=INPUT"
halow_boot_id_record
reconcile_rc; assert_eq "0" "$REC_RC" "reconcile 0"
assert_failure "record cleared" halow_own_check fw_created_input4
assert_eq "0" "$(fw_log_count ' -X INPUT')" "no INPUT delete was issued"
halow_test_teardown

echo "   same boot, the recorded chain now holds the host's own rule: kept, the claim dropped, reconcile still 0"
fresh_fw no no
fw_install
fw iptables -A INPUT -p tcp --dport 22 -j ACCEPT
halow_boot_id_record
reconcile_rc; assert_eq "0" "$REC_RC" "reconcile 0"
assert_success "the host's INPUT chain is kept" fw_base_present iptables INPUT
assert_eq "-p tcp --dport 22 -j ACCEPT" "$(fw_rules iptables filter INPUT)" "with its own rule only"
assert_failure "claim dropped" halow_own_check fw_created_input4
halow_test_teardown

echo "   same boot, a pre-existing empty INPUT chain: never removed"
fresh_fw yes yes
fw_install
halow_boot_id_record
reconcile_rc; assert_eq "0" "$REC_RC" "reconcile 0"
assert_success "the host's empty INPUT chain stays (IPv4)" fw_base_present iptables INPUT
assert_success "(IPv6)" fw_base_present ip6tables INPUT
assert_eq "0" "$(fw_log_count ' -X INPUT')" "no INPUT delete was issued"
halow_test_teardown

echo "   boot id changed: a stale creation record is dropped and a chain present now (the host's) is never removed"
fresh_fw yes yes
halow_boot_id_record
halow_own_mark fw_created_input4 "table=filter chain=INPUT"
halow_own_mark fw_created_input6 "table=filter chain=INPUT"
printf '%s\n' "$BOOT_B" > "$HALOW_BOOT_ID_FILE"
reconcile_rc; assert_eq "0" "$REC_RC" "reconcile 0"
assert_failure "stale record dropped (IPv4)" halow_own_check fw_created_input4
assert_failure "stale record dropped (IPv6)" halow_own_check fw_created_input6
assert_success "the empty INPUT chain present after the reboot stays" fw_base_present iptables INPUT
assert_eq "0" "$(fw_log_count ' -X INPUT')" "no INPUT delete was issued"
assert_success "noted" grep -q 'stale marker fw_created_input4 cleared after a reboot' <<< "$HALOW_RECONCILE_NOTES"
halow_test_teardown

echo "   the deletion cannot be confirmed: reconcile 1, the record named in the residue and kept"
fresh_fw no yes
fw_install
halow_boot_id_record
export HALOW_FAKE_FW_FAIL_MATCH="-X INPUT"
reconcile_rc; assert_eq "1" "$REC_RC" "reconcile 1"
unset HALOW_FAKE_FW_FAIL_MATCH
assert_success "named in the residue" grep -q 'fw_created_input4' <<< "$HALOW_RECONCILE_RESIDUAL"
assert_success "the chain is untouched" fw_base_present iptables INPUT
assert_success "the record is kept" halow_own_check fw_created_input4
reconcile_rc; assert_eq "0" "$REC_RC" "the retry succeeds"
assert_failure "chain removed" fw_base_present iptables INPUT
halow_test_teardown

echo "test_reconcile: $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed"
exit $([ "$HALOW_TEST_FAILURES" -eq 0 ] && echo 0 || echo 1)
