#!/usr/bin/env bash
# Shared helpers for the radio test suites (tests/test_radio*.sh). Sourced after
# test_helpers.sh; defines functions and expected values only.

RADIO_ADDON_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# RADIO_TABLE_OVERRIDE points the suites at another table on purpose (mutation checks).
RADIO_TABLE_SRC="${RADIO_TABLE_OVERRIDE:-$RADIO_ADDON_ROOT/rootfs/usr/share/halow/radio_profiles.psv}"
# RADIO_TEMPLATE_OVERRIDE lets the suites be run against the built-in fixture on purpose.
RADIO_TEMPLATE_SRC="${RADIO_TEMPLATE_OVERRIDE:-$RADIO_ADDON_ROOT/artifacts/hostapd_s1g.conf}"

# Expected AU facts (IEEE 802.11-2024 channelisation, driver scheme 2), typed here
# independently of the profile table so that a wrong table row fails the tests. Source:
# driver dot11ah/s1g_channels_rules.c au_2024_s1g_channels[] and hostap src/utils/morse.c
# au22..au25 (global operating classes 50..53).
RADIO_EXPECT_SCHEME=2
declare -gA RADIO_EXPECT_CHANNELS=(
    [1]="28 30 32 34 36 38 40 42 44 46 48 50"
    [2]="29 33 37 41 45 49"
    [4]="31 39 47"
    [8]="35 43"
)
# Frequencies (kHz) written out one by one, not computed, so that a wrong frequency in the
# table fails even if the formula check were wrong.
declare -gA RADIO_EXPECT_FREQS=(
    [1]="916000 917000 918000 919000 920000 921000 922000 923000 924000 925000 926000 927000"
    [2]="916500 918500 920500 922500 924500 926500"
    [4]="917500 921500 925500"
    [8]="919500 923500"
)
declare -gA RADIO_EXPECT_OPCLASS=( [1]=50 [2]=51 [4]=52 [8]=53 )
declare -gA RADIO_EXPECT_FALLBACK=( [1]=42 [2]=41 [4]=39 [8]=43 )
# The primary is always a 1 MHz channel at index 0; the driver then derives the primary
# channel as centre minus this offset (2 MHz: 1, 4 MHz: 3, 8 MHz: 7).
declare -gA RADIO_EXPECT_PRIM_OFFSET=( [1]=0 [2]=1 [4]=3 [8]=7 )
RADIO_EXPECT_PRIM_WIDTH=0
RADIO_EXPECT_PRIM_INDEX=0
# Regulatory spans (kHz, low:high) of the AU rules, an independent cross-check: every
# channel, as centre +- width/2, must lie inside one of them.
RADIO_EXPECT_REG_SPANS="915500:923500 919500:927500"
# The segment the fallbacks aim for: the channel nearest to this frequency (kHz), the lower
# channel on a tie.
RADIO_EXPECT_FALLBACK_TARGET_KHZ=923500
# Frequency start and channel separation (kHz) of the scheme.
RADIO_EXPECT_FREQ_START=902000
RADIO_EXPECT_CHAN_SEP=500

# radio_expect_nearest <bw> : prints the channel of the expected set (typed above) whose
# centre frequency is nearest to the fallback target, the lower one on a tie.
radio_expect_nearest() {
    local bw="$1" c best="" bestd="" d f
    for c in ${RADIO_EXPECT_CHANNELS[$bw]}; do
        f=$((RADIO_EXPECT_FREQ_START + RADIO_EXPECT_CHAN_SEP * c))
        d=$((f - RADIO_EXPECT_FALLBACK_TARGET_KHZ)); [ "$d" -lt 0 ] && d=$((-d))
        if [ -z "$bestd" ] || [ "$d" -lt "$bestd" ]; then best="$c"; bestd="$d"; fi
    done
    printf '%s' "$best"
}

# radio_in_reg_span <centre_khz> <bw_mhz> : 0 when [centre - bw/2, centre + bw/2] lies inside
# one of the regulatory spans.
radio_in_reg_span() {
    local centre="$1" bw="$2" lo hi span
    lo=$((centre - bw * 500)); hi=$((centre + bw * 500))
    for span in $RADIO_EXPECT_REG_SPANS; do
        if [ "$lo" -ge "${span%%:*}" ] && [ "$hi" -le "${span##*:}" ]; then return 0; fi
    done
    return 1
}

# radio_setup : the common test environment plus a radio template in the artifacts dir and
# a table path pointing at the source-tree table.
radio_setup() {
    halow_test_setup
    mkdir -p "$HALOW_RUN_DIR"
    export HALOW_RADIO_PROFILES="$RADIO_TABLE_SRC"
    radio_install_template
}

# radio_install_template : the bundled template when the artifacts are staged; otherwise a
# fixture holding exactly the active (non-comment) lines of that template, so rendering is
# tested either way.
radio_install_template() {
    if [ -f "$RADIO_TEMPLATE_SRC" ]; then
        cp "$RADIO_TEMPLATE_SRC" "$HALOW_ARTIFACTS_DIR/hostapd_s1g.conf"
        RADIO_TEMPLATE_KIND="bundled"
        return 0
    fi
    RADIO_TEMPLATE_KIND="fixture"
    cat > "$HALOW_ARTIFACTS_DIR/hostapd_s1g.conf" <<'EOF'
interface=wlan0
#bridge=br0
logger_syslog=-1
logger_syslog_level=2
logger_stdout=-1
logger_stdout_level=2
ctrl_interface=/var/run/hostapd
ctrl_interface_group=0
ssid=test
country_code=AU
hw_mode=a
channel=42
op_class=50
beacon_int=100
dtim_period=2
max_num_sta=255
rts_threshold=-1
fragm_threshold=-1
macaddr_acl=0
auth_algs=3
ignore_broadcast_ssid=0
wmm_enabled=1
#ap_isolate=1
ieee80211ah=1
s1g_prim_chwidth=0
s1g_prim_1mhz_chan_index=0
s1g_capab=[SHORT-GI-ALL]
eapol_key_index_workaround=0
own_ip_addr=127.0.0.1
wpa=2
wpa_key_mgmt=SAE
rsn_pairwise=CCMP
ieee80211w=2
sae_pwe=2
wds_sta=1
EOF
}

# radio_conf_value <file> <key> : prints the value of the LAST active "<key>=" line.
radio_conf_value() {
    local file="$1" key="$2" line v=""
    while IFS= read -r line; do
        case "$line" in "$key="*) v="${line#*=}" ;; esac
    done < "$file"
    printf '%s' "$v"
}

# radio_conf_count <file> <key> : number of active "<key>=" lines.
radio_conf_count() {
    local file="$1" key="$2" line c=0
    while IFS= read -r line; do
        case "$line" in "$key="*) c=$((c + 1)) ;; esac
    done < "$file"
    printf '%s' "$c"
}

# radio_table_copy : prints the path of a writable copy of the table in the temp dir.
radio_table_copy() {
    local copy="$HALOW_TEST_TMP/radio_profiles_copy.psv"
    cp "$RADIO_TABLE_SRC" "$copy"
    printf '%s' "$copy"
}

radio_summary() { # radio_summary <suite>
    echo "$1: $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed"
    [ "$HALOW_TEST_FAILURES" -eq 0 ]
}
