#!/usr/bin/env bash
# Tests config.yaml and translations/en.yaml: the privilege set (exactly the grants the code
# uses, nothing broader, no udev), the Green-only target, Ingress without API access, the
# stop budget, backups, the static options schema (every option, its type and default, no
# interface-name option, a required passphrase with no default) and that every option has a
# plain-language translation and vice versa.
#
# Line-based checks need nothing but bash and awk. The structural checks parse both files
# with python3 and its yaml module; where that module is missing they are skipped with a
# visible note (the line-based privilege checks still run).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh

echo "== test_config_yaml =="

CONFIG="../config.yaml"
TRANS="../translations/en.yaml"
DOCKERFILE="../Dockerfile"

# The Australian IEEE 802.11-2024 channel sets, typed here independently of the radio profile
# table, so that a wrong profile row, schema list, translation or README fails the tests.
CH_1="28 30 32 34 36 38 40 42 44 46 48 50"
CH_2="29 33 37 41 45 49"
CH_4="31 39 47"
CH_8="35 43"
CH_UNION="$(seq 28 50 | paste -sd' ')"   # the union of the four sets is exactly 28..50

assert_file_exists "$CONFIG" "config.yaml exists"
assert_file_exists "$TRANS" "translations/en.yaml exists"
assert_file_exists "../apparmor.txt" "the AppArmor profile that apparmor: true refers to exists"

# _top <key> : prints the value of a top-level scalar key (quotes removed).
_top() { awk -v k="$1" '$0 ~ "^"k":" { sub("^"k":[[:space:]]*", ""); gsub(/^"|"$/, ""); print; exit }' "$CONFIG"; }
# _list <key> : prints the items of a top-level block list, space-separated.
_list() { awk -v k="$1" '$0 ~ "^"k":" {p=1; next} p && /^  - / {sub(/^  - /,""); gsub(/^"|"$/, ""); printf "%s ", $0; next} p {exit}' "$CONFIG"; }

echo "-- privileges: exactly what the code uses --"
assert_eq "true" "$(_top apparmor)" "apparmor: true (the shipped profile replaces Docker's default)"
assert_eq "true" "$(_top kernel_modules)" "kernel_modules: true (driver loading)"
assert_eq "true" "$(_top host_network)" "host_network: true"
assert_eq "true" "$(_top host_dbus)" "host_dbus: true (NetworkManager unmanaged marks)"
assert_eq "SYS_ADMIN NET_ADMIN NET_RAW " "$(_list privileged)" "privileged lists exactly SYS_ADMIN, NET_ADMIN and NET_RAW"
assert_eq "1" "$(grep -c '^privileged:' "$CONFIG")" "there is exactly one privileged key"
for key in udev full_access devices usb uart gpio ports ports_description watchdog \
           homeassistant_api hassio_api hassio_role auth_api docker_api host_pid host_ipc \
           host_uts audio video map tmpfs halow_interface; do
    assert_failure "config.yaml does not declare '$key'" grep -qE "^${key}:" "$CONFIG"
done
assert_failure "udev appears nowhere in the manifest's keys or schema" grep -qE '^[[:space:]]*udev[[:space:]]*:' "$CONFIG"
assert_failure "no inline list form that these line checks could not see" grep -qE '^(machine|arch|privileged|breaking_versions|backup_exclude):[[:space:]]*\[' "$CONFIG"

echo "-- target: aarch64 on the Home Assistant Green only --"
assert_eq "1" "$(grep -c "^arch:" "$CONFIG")" "there is exactly one arch key"
assert_eq "1" "$(grep -c "^machine:" "$CONFIG")" "there is exactly one machine key (a duplicate would win in a YAML loader)"
assert_eq "aarch64 " "$(_list arch)" "arch lists exactly aarch64"
assert_eq "green " "$(_list machine)" "machine lists exactly green (not every aarch64 machine)"
README_FLAT="$(tr '\n' ' ' < ../README.md | tr -s ' ')"   # the README on one line, so wrapped phrases can be matched
assert_success "the README says Home Assistant Green running Home Assistant OS 18.4 is supported in this release" grep -qF "Home Assistant Green** running Home Assistant OS 18.4 is supported in this release" <<< "$README_FLAT"
assert_success "the README says the USB-A and USB-C adapter versions are both supported" grep -qF "The USB-A and USB-C versions are both supported" <<< "$README_FLAT"
assert_failure "the README names no USB ID and no firmware path (the License section may name the firmware license)" grep -qiE "325b:8100|usb id|/lib/firmware|firmware (path|search)" ../README.md

echo "-- runtime model --"
assert_eq "false" "$(_top init)" "init: false (the base image's s6 is PID 1)"
assert_eq "application" "$(_top startup)" "startup: application"
assert_eq "auto" "$(_top boot)" "boot: auto"
assert_eq "true" "$(_top ingress)" "ingress: true"
assert_eq "0" "$(_top ingress_port)" "ingress_port: 0 (Supervisor-assigned port)"
assert_success "the panel has a title" test -n "$(_top panel_title)"
assert_success "the panel icon is a Material Design icon" grep -qE '^panel_icon:[[:space:]]+mdi:[a-z0-9-]+$' "$CONFIG"

echo "-- version, breaking versions, image labels --"
version="$(_top version)"
assert_eq "1.0.0" "$version" "version is 1.0.0, the first release"
assert_success "breaking_versions lists the earlier development version that made the options change" grep -qx '  - "0.0.1-dev"' "$CONFIG"
assert_success "breaking_versions still lists 0.2.0-dev, the version that changed the saved options" grep -qx '  - "0.2.0-dev"' "$CONFIG"
assert_failure "breaking_versions does not list this version (it changes no saved option)" grep -qx "  - \"$version\"" "$CONFIG"
assert_eq "2" "$(grep -cE '^  - "[0-9]' "$CONFIG")" "breaking_versions holds exactly two versions"
assert_success "the OCI image version label equals the manifest version" grep -qF "org.opencontainers.image.version=\"$version\"" "$DOCKERFILE"
assert_success "the README names the same version" grep -qF "\`$version\`" ../README.md
assert_success "the image's io.hass.version label equals the manifest version" grep -qF "io.hass.version=\"$version\"" "$DOCKERFILE"
assert_eq "2" "$(grep -cE '^[[:space:]]*(io\.hass\.version|org\.opencontainers\.image\.version)=' "$DOCKERFILE")" "the Dockerfile carries exactly the two version labels (none stale)"

echo "-- README: the per-bandwidth channel table states the 802.11-2024 sets --"
for bw in 1 2 4 8; do
    _t="CH_$bw"
    readme_row="$(grep -m1 "^| $bw MHz |" ../README.md)"
    assert_success "the README has a channel table row for $bw MHz" test -n "$readme_row"
    parsed="$(printf '%s\n' "$readme_row" | awk -F'|' '{ print $3 }' | tr -d ',' | xargs)"
    assert_eq "${!_t}" "$parsed" "the README channel table lists exactly the $bw MHz channels of the 802.11-2024 table"
done
assert_eq "28 30 32 34 36 38 40 42 44 46 48 50" "$CH_1" "the 1 MHz set is every even channel 28..50 (table self-check)"
assert_success "the README names the IEEE 802.11-2024 channel numbers" grep -qF "IEEE 802.11-2024" <<< "$README_FLAT"
assert_failure "the README does not offer the 2020 numbering as a choice" grep -qiE "802\.11-2020|scheme 1|operating class 6[89]|operating class 7[01]" ../README.md
assert_success "the README says bandwidth is always the customer's choice" grep -qF "Bandwidth is the width of the channel, and you always choose it" <<< "$README_FLAT"
assert_success "the README says the channel selection mode does not change the bandwidth" grep -qF "This does not change the bandwidth." <<< "$README_FLAT"
assert_success "the README says automatic selection picks a channel at each start and manual always uses the set channel" bash -c 'grep -qF "Automatic chooses a channel each time the app starts" <<< "$0" && grep -qF "Manual always uses the Channel you set" <<< "$0"' "$README_FLAT"
assert_success "the README says that in manual mode the channel must fit the bandwidth" grep -qF "In manual mode the channel must fit the bandwidth" <<< "$README_FLAT"
assert_success "the README says the channel is ignored in automatic mode" grep -qF "In Automatic mode, this setting is ignored" ../README.md
assert_success "the README says a manual channel that does not fit stops the access point and the status page names the setting" grep -qF "channel that does not fit the bandwidth stops the access point from starting, and the status page names the setting" <<< "$README_FLAT"
assert_success "the README says the passphrase is required with no default" grep -qF "It is required and has no default" <<< "$README_FLAT"
assert_success "the README says the passphrase is 12 to 63 standard keyboard characters" grep -qF "12 to 63 characters, using only standard keyboard characters" <<< "$README_FLAT"
assert_success "the README says the passphrase is included in backups" grep -qF "includes its settings, including the passphrase" <<< "$README_FLAT"
assert_success "the README says the allowed ports are empty by default" grep -qE "^\| Allowed ports \| empty \|" ../README.md
assert_success "the README says each allowed port entry exposes a service to every device on the Wi-Fi HaLow network" grep -qF "Each entry you add makes a service reachable to every device on the Wi-Fi HaLow network" <<< "$README_FLAT"
assert_success "the README says changes take effect when the app is restarted" grep -qF "Changes take effect when you restart the app" <<< "$README_FLAT"
cfg_desc="$(sed -n '/^description:/,/^stage:/p' "$CONFIG" | sed '1d;$d' | tr '\n' ' ' | tr -s ' ')"
assert_success "the config.yaml description is customer text and is not empty" test -n "${cfg_desc// /}"
assert_failure "the config.yaml description and panel title do not say development build, not production-ready or not live-validated" grep -qiE "development build|not production-ready|not live-validated" <<< "$cfg_desc $(_top panel_title)"
assert_eq "Wi-Fi HaLow" "$(_top panel_title)" "the panel title is Wi-Fi HaLow"

echo "-- customer text rules: README, translations, config description --"
customer_all="$(cat ../README.md "$TRANS"; printf '%s\n' "$cfg_desc")"
assert_eq "0" "$(printf '%s\n' "$customer_all" | grep -c -P '\xe2\x80\x94')" "no em dash in the customer text"
assert_failure "HaLow never stands alone in customer text (always Wi-Fi HaLow)" bash -c 'tr "\n" " " <<< "$0" | tr -s " " | sed -e "s/HaLow-Network//g" -e "s/Wi-Fi HaLow//g" -e "s/Wi-Fi-HaLow//g" | grep -q "HaLow"' "$customer_all"
assert_failure "no customer text says development build, not production-ready, not live-validated or limited evidence" grep -qiE "development build|not production-ready|not live-validated|limited evidence|live-validated" <<< "$customer_all"
assert_failure "no customer text carries device-test anecdotes (Windows adapter, HaLowLink, probe request, hostapd, stale form)" grep -qiE "windows|halowlink|probe[- ]request|hostapd|stale form|stale-form|cold-started|source analysis" <<< "$customer_all"
assert_failure "the customer text says app, not add-on, except for the one explanation of the earlier name" bash -c 'tr "\n" " " <<< "$0" | tr -s " " | sed "s/(called an add-on in earlier versions of Home Assistant)//" | grep -qiE "add-on"' "$customer_all"
assert_success "the config.yaml description is the approved customer sentence" grep -qF "Turn your Home Assistant Green into a Wi-Fi HaLow access point with the Morse Micro Wi-Fi HaLow USB Network Adapter." <<< "$cfg_desc"
assert_failure "no customer text says 'the Green' (always Home Assistant Green)" bash -c 'tr "\n" " " <<< "$0" | tr -s " " | sed "s/Home Assistant Green//g" | grep -qE "[Tt]he Green"' "$customer_all"
assert_failure "no customer text carries a numbered group tag like [1 " grep -qE '\[[0-9] ' <<< "$customer_all"
assert_failure "no customer text carries a placeholder" grep -qiE "PLACEHOLDER|TODO|TBD|lorem" <<< "$customer_all"
assert_failure "no customer text mentions a security rating" grep -qi "security rating" <<< "$customer_all"
assert_failure "no customer text mentions taint, unsigned drivers, a firmware path, the local apps folder or internal documents" grep -qiE "taint|unsigned|firmware path|/lib/firmware|local apps|OPERATIONS\.md|PROVENANCE|SOURCE-OFFER|network interruption" <<< "$customer_all"
assert_failure "no customer text names reserved or refused ports or the internal ports 22222, 4357, 62000, 8123" grep -qiE "refused|reserved|22222|4357|62000|65500|8123" <<< "$customer_all"
assert_eq "tcp/1883 udp/5353" "$(grep -oE '(tcp|udp)/[0-9]+' <<< "$customer_all" | sort -u | paste -sd' ')" "the only port examples in customer text are tcp/1883 and udp/5353"
assert_eq "https://github.com/MorseMicroLabs/home-assistant-halow/issues https://www.morsemicro.com/ https://www.morsemicro.com/policy/security-disclosure https://www.morsemicro.com/products/development-resources/wi-fi-halow-usb-network-adapters" "$(grep -oE 'https?://[^) ]+' ../README.md | sort -u | paste -sd' ')" "the README has exactly the approved links (Morse Micro home and product pages, the security-disclosure form, GitHub Issues)"
assert_eq "3" "$(grep -cE 'https?://' ../README.md)" "the README has exactly three lines with a link"
assert_failure "no customer text carries a raw URL outside the README's two approved links" grep -qE 'https?://' <<< "$(cat "$TRANS"; printf '%s\n' "$cfg_desc")"
assert_failure "the README has no Source code and licenses section and no source record file names" grep -qiE "source code and licen|PROVENANCE\.md|SOURCE-OFFER\.md" ../README.md

echo "-- stop budget: the Supervisor timeout exceeds the s6 grace times --"
timeout_s="$(_top timeout)"
assert_success "timeout is an integer within the documented 10-300 seconds" \
    bash -c '[[ $0 =~ ^[0-9]+$ ]] && [ "$0" -ge 10 ] && [ "$0" -le 300 ]' "$timeout_s"
grace_ms="$(grep -oE 'S6_SERVICES_GRACETIME=[0-9]+' "$DOCKERFILE" | cut -d= -f2)"
kill_ms="$(grep -oE 'S6_KILL_GRACETIME=[0-9]+' "$DOCKERFILE" | cut -d= -f2)"
assert_success "the Dockerfile sets S6_SERVICES_GRACETIME and S6_KILL_GRACETIME" test -n "${grace_ms}" -a -n "${kill_ms}"
assert_success "timeout (s) > S6_SERVICES_GRACETIME + S6_KILL_GRACETIME, so s6 finishes before the Supervisor kills" \
    test "$(( ${timeout_s:-0} * 1000 ))" -gt "$(( ${grace_ms:-999999} + ${kill_ms:-999999} ))"
finish_limit="../rootfs/etc/services.d/manager/timeout-finish"
if [ -f "$finish_limit" ]; then
    assert_success "the manager's finish time limit fits inside the s6 service grace time" \
        test "$(tr -dc '0-9' < "$finish_limit")" -lt "${grace_ms:-0}"
else
    echo "  note: rootfs/etc/services.d/manager/timeout-finish is not present; s6's default finish limit (5 s) applies"
fi

echo "-- backups --"
assert_success "backup_exclude excludes the add-on's markers" grep -qx '  - "halow_state"' "$CONFIG"
assert_success "backup_exclude excludes the staged firmware" grep -qx '  - "halow_fw"' "$CONFIG"
assert_success "backup_exclude excludes the DHCP lease directory (client MAC and IP addresses never enter a backup)" grep -qx '  - "halow_leases"' "$CONFIG"
assert_success "backup_exclude excludes the lease directory contents too" grep -qx '  - "halow_leases/**"' "$CONFIG"
assert_failure "backup_exclude does not exclude the options file (the comment and README say it is backed up)" grep -qE '^  - "options' "$CONFIG"
assert_failure "the manifest does not claim the options are stored outside /data" grep -qi "outside /data" "$CONFIG"
assert_success "the manifest says the options (with the passphrase) are in /data/options.json and in every backup" \
    bash -c 'grep -qF "/data/options.json" "$0" && grep -qi "part of every backup" "$0"' "$CONFIG"
assert_success "the SYS_ADMIN comment names the /run/halow tmpfs mount" grep -qE 'tmpfs the$|tmpfs .*/run/halow|/run/halow' "$CONFIG"

echo "-- options schema (structural; needs python3 with yaml) --"
if python3 -c 'import yaml' >/dev/null 2>&1; then
    flat="$(python3 - "$CONFIG" "$TRANS" <<'PY'
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
tr = yaml.safe_load(open(sys.argv[2], encoding="utf-8"))
print("parsed=yes")
schema = cfg.get("schema") or {}
options = cfg.get("options") or {}
print("schema_keys=" + " ".join(sorted(schema)))
print("option_keys=" + " ".join(sorted(options)))
print("schema_order=" + " ".join(schema))
print("option_order=" + " ".join(options))
print("trans_order=" + " ".join(((tr or {}).get("configuration") or {})))
for k, v in schema.items():
    print("schema.%s=%s" % (k, ("list:" + "|".join(map(str, v))) if isinstance(v, list) else v))
for k, v in options.items():
    print("option.%s=%s" % (k, ("list:" + "|".join(map(str, v))) if isinstance(v, list) else v))
conf = (tr or {}).get("configuration") or {}
print("trans_keys=" + " ".join(sorted(conf)))
for k, v in conf.items():
    v = v or {}
    print("trans.%s.name=%s" % (k, " ".join(str(v.get("name", "")).split())))
    print("trans.%s.description=%s" % (k, " ".join(str(v.get("description", "")).split())))
for k in ("privileged", "arch", "machine", "breaking_versions", "backup_exclude"):
    print("%s=%s" % (k, " ".join(map(str, cfg.get(k) or []))))
for k in ("ingress_port", "timeout", "apparmor", "init", "udev", "full_access", "ingress"):
    print("%s=%r" % (k, cfg.get(k)))
PY
)"
    _f() { printf '%s\n' "$flat" | awk -v k="$1" 'index($0, k"=") == 1 { print substr($0, length(k) + 2); exit }'; }
    assert_eq "yes" "$(_f parsed)" "both files parse as YAML"
    assert_eq "allowed_ports bandwidth channel dhcp_range_end dhcp_range_start halow_subnet_cidr radio_mode region uplink_interface wifi_passphrase wifi_ssid" \
        "$(_f schema_keys)" "the schema has exactly the documented options (no interface-name option)"
    assert_eq "allowed_ports bandwidth channel dhcp_range_end dhcp_range_start halow_subnet_cidr radio_mode region uplink_interface wifi_ssid" \
        "$(_f option_keys)" "a default exists for every option except the passphrase (so the form shows every option from first install)"
    assert_eq "11" "$(printf '%s\n' "$(_f schema_keys)" | wc -w)" "the schema holds exactly 11 options"
    # Home Assistant renders the form in schema order and has no headings, so the order is the
    # customer's sequence: pin it in the schema, the defaults and the translations.
    FORM_ORDER="wifi_ssid wifi_passphrase region bandwidth radio_mode channel halow_subnet_cidr dhcp_range_start dhcp_range_end uplink_interface allowed_ports"
    assert_eq "$FORM_ORDER" "$(_f schema_order)" "the schema lists the options in the form order"
    assert_eq "$FORM_ORDER" "$(_f option_order | sed 's/^wifi_ssid /wifi_ssid wifi_passphrase /')" "the defaults follow the same order (the passphrase has none)"
    assert_eq "$FORM_ORDER" "$(_f trans_order)" "the translations follow the same order"
    assert_eq "0" "$(printf '%s\n' "$flat" | grep -c '^schema\.[a-z_]*=.*?$')" "no option is an optional ('?') entry: the form would hide it behind its 'show unused optional' switch"
    assert_eq "SYS_ADMIN NET_ADMIN NET_RAW" "$(_f privileged)" "parsed privileged list"
    assert_eq "0" "$(_f ingress_port)" "parsed ingress_port is the integer 0"
    assert_eq "True" "$(_f apparmor)" "parsed apparmor is boolean true"
    assert_eq "False" "$(_f init)" "parsed init is boolean false"
    assert_eq "None" "$(_f udev)" "parsed udev is absent"
    assert_eq "None" "$(_f full_access)" "parsed full_access is absent"
    assert_eq "list(AU)" "$(_f schema.region)" "region offers AU only"
    assert_eq "AU" "$(_f option.region)" "region defaults to AU"
    assert_eq "list(automatic|manual)" "$(_f schema.radio_mode)" "radio_mode is automatic or manual"
    assert_eq "automatic" "$(_f option.radio_mode)" "radio_mode defaults to automatic"
    assert_eq "list(1|2|4|8)" "$(_f schema.bandwidth)" "bandwidth offers 1, 2, 4 and 8 MHz"
    dev_default="$(sed -n 's/^: "\${HALOW_DEFAULT_BANDWIDTH_MHZ:=\([0-9]*\)}"$/\1/p' ../rootfs/usr/lib/halow/constants.sh)"
    assert_eq "${dev_default:-missing}" "$(_f option.bandwidth)" "the bandwidth default equals the code's development default"
    psv_union="$(awk -F'|' '$1 == "width" { n = split($11, a, " "); for (i = 1; i <= n; i++) { split(a[i], c, ":"); print c[1] } }' ../rootfs/usr/share/halow/radio_profiles.psv | sort -nu | paste -sd'|')"
    assert_eq "list(auto|${psv_union})" "$(_f schema.channel)" "channel is a required list: the sentinel auto plus exactly the union of the channels of every region in the radio profile table"
    psv_regions="$(awk -F'|' '$1 == "region" { print $3 }' ../rootfs/usr/share/halow/radio_profiles.psv | sort -u | paste -sd'|')"
    assert_eq "list(${psv_regions})" "$(_f schema.region)" "every region in the radio profile table is offered in the region schema list (and no other)"
    assert_eq "auto" "$(_f option.channel)" "channel defaults to the sentinel auto (never a channel that could be invalid for another bandwidth)"
    assert_failure "the channel default is not a number" bash -c '[[ $0 =~ ^[0-9]+$ ]]' "$(_f option.channel)"
    assert_eq "str" "$(_f schema.uplink_interface)" "uplink_interface is a required string (always shown)"
    assert_eq "" "$(_f option.uplink_interface)" "uplink_interface defaults to empty (the default-route interface)"
    assert_success "wifi_passphrase is a password type with a minimum of 12 and a maximum of 63" test "$(_f schema.wifi_passphrase)" = "password(12,63)"
    assert_eq "" "$(_f option.wifi_passphrase)" "wifi_passphrase has no default (the form requires it before start)"
    assert_success "wifi_ssid is 1-32 characters in the form" test "$(_f schema.wifi_ssid)" = "str(1,32)"
    assert_eq "list:" "$(_f option.allowed_ports)" "allowed_ports defaults to an empty list"
    assert_success "allowed_ports is a list of matched strings" bash -c '[[ $0 == list:match\(* ]]' "$(_f schema.allowed_ports)"
    rx="$(_f schema.allowed_ports)"; rx="${rx#list:match(}"; rx="${rx%)}"
    for good in tcp/1883 udp/5683 tcp/1; do
        assert_success "the allowed_ports pattern accepts $good" python3 -c 'import re,sys; sys.exit(0 if re.fullmatch(sys.argv[1], sys.argv[2]) else 1)' "$rx" "$good"
    done
    for bad in "tcp 1883" "icmp/1" "tcp/" "TCP/80" "tcp/1883;x" "tcp/123456"; do
        assert_failure "the allowed_ports pattern rejects '$bad'" python3 -c 'import re,sys; sys.exit(0 if re.fullmatch(sys.argv[1], sys.argv[2]) else 1)' "$rx" "$bad"
    done
    assert_failure "no option default looks like a secret" bash -c 'printf "%s\n" "$0" | grep -qiE "^option\.[a-z_]*(pass|secret|token|key)"' "$flat"

    echo "-- the defaults pass the add-on's own validators --"
    halow_test_setup
    assert_success "the default SSID is valid" halow_validate_ssid "$(_f option.wifi_ssid)"
    assert_success "the default subnet is a valid CIDR" halow_validate_ipv4_cidr "$(_f option.halow_subnet_cidr)"
    assert_success "the default DHCP range is valid inside the default subnet" \
        halow_validate_dhcp_range "$(_f option.dhcp_range_start)" "$(_f option.dhcp_range_end)" "$(_f option.halow_subnet_cidr)"
    halow_test_teardown

    echo "-- translations: every option has a name and description, and only options do --"
    assert_eq "$(_f schema_keys)" "$(_f trans_keys)" "the translation keys equal the schema keys"
    for key in $(_f schema_keys); do
        assert_success "option $key has a translated name" test -n "$(_f "trans.$key.name")"
        assert_success "option $key has a plain-language description" test "$(_f "trans.$key.description" | wc -w)" -ge 8
    done
    chdesc="$(_f trans.channel.name) $(_f trans.channel.description)"
    assert_eq "Network name (SSID)" "$(_f trans.wifi_ssid.name)" "the ssid label is Network name (SSID)"
    assert_eq "Network passphrase" "$(_f trans.wifi_passphrase.name)" "the passphrase label is Network passphrase"
    assert_eq "Region" "$(_f trans.region.name)" "the region label is Region"
    assert_eq "Bandwidth (MHz)" "$(_f trans.bandwidth.name)" "the bandwidth label is Bandwidth (MHz)"
    assert_eq "Channel selection mode" "$(_f trans.radio_mode.name)" "the radio_mode label is Channel selection mode"
    assert_eq "Channel (manual mode only)" "$(_f trans.channel.name)" "the channel label says it applies in manual mode only"
    assert_eq "Wi-Fi HaLow network address" "$(_f trans.halow_subnet_cidr.name)" "the subnet label is Wi-Fi HaLow network address"
    assert_eq "First client address" "$(_f trans.dhcp_range_start.name)" "the DHCP start label is First client address"
    assert_eq "Last client address" "$(_f trans.dhcp_range_end.name)" "the DHCP end label is Last client address"
    assert_eq "Uplink interface" "$(_f trans.uplink_interface.name)" "the uplink label is Uplink interface"
    assert_eq "Allowed ports" "$(_f trans.allowed_ports.name)" "the allowed_ports label is Allowed ports"
    assert_failure "no label still says Radio mode" grep -qi "radio mode" <<< "$(printf '%s\n' "$flat" | grep '^trans\..*\.name=')"
    # No numbered group tags or group prefixes: Home Assistant shows no headings, and the
    # approved copy leaves each description to stand on its own.
    for k in $(_f schema_keys); do
        assert_failure "$k description carries no numbered group tag or [group] prefix" grep -qE '^\[|\[[0-9] ' <<< "$(_f trans.$k.description)"
    done
    # Channel: used in manual mode, must match the bandwidth; the channel table lives in the README.
    chd="$(_f trans.channel.description)"
    assert_success "channel says it is used only in manual mode and to leave it on auto otherwise" grep -qF "Used only in manual mode; leave it on auto otherwise." <<< "$chd"
    assert_success "channel says the channel must match the bandwidth and points to the channel table on the Info page" grep -qF "The channel must match your bandwidth (see the channel table on the Info page)." <<< "$chd"
    assert_success "channel says to check it whenever the bandwidth changes" grep -qF "Check it whenever you change the bandwidth." <<< "$chd"
    assert_failure "channel does not mention the 2020 numbering, a stale channel list or an MHz list (the README holds the table)" grep -qE "2020|[0-9] MHz:" <<< "$chd"
    # The schema list is exactly the sentinel plus 28..50, which equals the union of the table sets.
    assert_eq "$CH_UNION" "$(printf '%s\n' $CH_1 $CH_2 $CH_4 $CH_8 | sort -n | paste -sd' ')" "the explicit table's four sets together are exactly 28..50 with no overlap (table self-check)"
    assert_eq "list(auto|$(printf '%s' "$CH_UNION" | tr ' ' '|'))" "$(_f schema.channel)" "the channel schema list is exactly auto plus the table union 28..50"
    # The README channel table must equal the radio profile table.
    psv=../rootfs/usr/share/halow/radio_profiles.psv
    if [ -f "$psv" ]; then
        for bw in 1 2 4 8; do
            chans="$(awk -F'|' -v bw="$bw" '$1 == "width" && $3 == "AU" && $4 == bw { n = split($11, a, " "); for (i = 1; i <= n; i++) { split(a[i], c, ":"); printf "%s%s", (i > 1 ? ", " : ""), c[1] } }' "$psv")"
            assert_success "the README $bw MHz channel row matches the radio profile table ($chans)" grep -qF "| $bw MHz | $chans |" ../README.md
        done
    fi
    # Radio mode: automatic and manual describe the CHANNEL selection, never the bandwidth.
    rmdesc="$(_f trans.radio_mode.description)"
    assert_success "radio_mode explains automatic as picking a channel each time the app starts" grep -qF "Automatic: the app picks a channel each time it starts." <<< "$rmdesc"
    assert_success "radio_mode explains manual as always using the channel set in Channel" grep -qF "Manual: it always uses the channel set in Channel." <<< "$rmdesc"
    assert_success "radio_mode says the bandwidth is not affected" grep -qF "Bandwidth is not affected." <<< "$rmdesc"
    assert_failure "no description says that automatic mode controls the bandwidth" grep -qiE "automatic (mode )?(chooses|selects|controls) (the )?bandwidth" <<< "$flat"
    # Bandwidth: always the customer's choice.
    bwdesc="$(_f trans.bandwidth.description)"
    assert_success "bandwidth lists the choices 1, 2, 4, or 8 MHz" grep -qF "1, 2, 4, or 8" <<< "$bwdesc"
    assert_success "bandwidth says the customer always chooses it and the app never changes it" grep -qF "You always choose it; the app never changes it." <<< "$bwdesc"
    assert_success "bandwidth says that in manual mode the channel must match" grep -qF "In manual mode, the channel must match." <<< "$bwdesc"
    # Passphrase.
    ppdesc="$(_f trans.wifi_passphrase.description)"
    assert_success "the passphrase description says it is required" grep -qF "Required." <<< "$ppdesc"
    assert_success "the passphrase description states the 12 to 63 character range with standard keyboard characters only" grep -qF "12 to 63 characters, using only standard keyboard characters (no accented letters or emoji)" <<< "$ppdesc"
    assert_success "the passphrase description says the app does not start until one is set" grep -qF "The app does not start until you set one." <<< "$ppdesc"
    assert_success "the passphrase description says it is included in backups so backups should be kept private" grep -qF "It is included in Home Assistant backups, so keep backups private." <<< "$ppdesc"
    # SSID, region, addressing.
    assert_success "the ssid description states the 32 character limit" grep -qF "Up to 32 characters" <<< "$(_f trans.wifi_ssid.description)"
    assert_success "the ssid description says backslashes and line breaks are not accepted" grep -qF "Backslashes and line breaks are not accepted" <<< "$(_f trans.wifi_ssid.description)"
    assert_success "the region description says Australia is supported in this release" grep -qF "Australia is supported in this release" <<< "$(_f trans.region.description)"
    assert_success "the region description says more regions are planned" grep -qF "Support for additional regions is planned for future releases" <<< "$(_f trans.region.description)"
    assert_success "the subnet description gives the example address 192.168.90.1/24" grep -qF "192.168.90.1/24" <<< "$(_f trans.halow_subnet_cidr.description)"
    assert_success "the subnet description says it must not overlap a network already in use" grep -qF "It must not overlap a network you already use." <<< "$(_f trans.halow_subnet_cidr.description)"
    # The default network name is Wi-Fi-HaLow, and README, config and translations agree on it.
    assert_eq "Wi-Fi-HaLow" "$(_f option.wifi_ssid)" "the default wifi_ssid in config.yaml is exactly Wi-Fi-HaLow"
    assert_success "the README settings table names the same default network name" grep -qF '| Network name (SSID) | `Wi-Fi-HaLow` |' ../README.md
    assert_success "the default network name is a valid SSID" halow_validate_ssid "Wi-Fi-HaLow"
    assert_eq "0" "$(cat ../README.md "$TRANS" "$CONFIG" | grep -c 'HaLow-Network')" "no stale default network name (HaLow-Network) remains in the README, translations or config"
    assert_failure "the translated ssid description names no default network name of its own (the default is stated in the README and config only)" grep -qiE "default|HaLow-" <<< "$(_f trans.wifi_ssid.description)"
    # Allowed ports.
    apdesc="$(_f trans.allowed_ports.description)"
    assert_success "allowed_ports says to leave it empty unless needed" grep -qF "Leave empty unless you need it." <<< "$apdesc"
    assert_success "allowed_ports gives the entry form tcp/1883 or udp/5353 in lower case" grep -qF "tcp/1883 or udp/5353 (lower case)" <<< "$apdesc"
    assert_success "allowed_ports warns: an entry makes a service reachable to every device on the network" grep -qF "Each entry makes a service reachable to every device on the network" <<< "$apdesc"
    assert_success "allowed_ports warns: add only services you understand and intend to expose" grep -qF "add only services you understand and intend to expose" <<< "$apdesc"
    assert_success "allowed_ports says that without entries devices reach only DHCP, DNS and ping" grep -qF "devices reach only DHCP (address assignment), DNS (name lookup), and ping" <<< "$apdesc"
    assert_eq "1883 5353" "$(grep -oE '[0-9]{2,5}' <<< "$apdesc" | sort -u | paste -sd' ')" "allowed_ports names no port number other than the examples 1883 and 5353"
    assert_failure "allowed_ports mentions no refused, reserved or administrative ports" grep -qiE "administrative|refused|reserved|SSH|22222|62000|4357" <<< "$apdesc"
    assert_failure "no customer-facing translation text mentions port 8123" grep -q "8123" "$TRANS"
    # Uplink.
    updesc="$(_f trans.uplink_interface.description)"
    assert_success "the uplink description is the approved text" test "$updesc" = "The network interface your Wi-Fi HaLow devices use to reach your network and the internet. Leave empty to use the interface associated with the default route. If default routes use more than one interface, the app cannot choose between them; enter the interface name here. Advanced: a physical network interface name such as end0."
    assert_success "the uplink description says empty uses the interface associated with the default route" grep -qF "Leave empty to use the interface associated with the default route." <<< "$updesc"
    assert_success "the uplink description says default routes using more than one interface need an interface name" grep -qF "If default routes use more than one interface, the app cannot choose between them; enter the interface name here." <<< "$updesc"
    assert_failure "the uplink description does not call the setting a connection (the app needs a Linux interface name)" grep -qiE "connection" <<< "$updesc"
    assert_failure "the uplink description does not imply that only Home Assistant Green is supported" grep -qE "Green" <<< "$updesc"
    assert_success "the uplink description gives the example end0 as an advanced setting" grep -qF "Advanced: a physical network interface name such as end0." <<< "$updesc"
    echo "-- the documented validators agree with the descriptions --"
    halow_test_setup
    assert_failure "the passphrase validator refuses a non-ASCII passphrase the description excludes" halow_validate_passphrase "passphrase-ümlaut"
    assert_failure "the uplink validator refuses hassio, as the description says" halow_validate_uplink_name hassio
    assert_success "the uplink validator accepts the description's example end0" halow_validate_uplink_name end0
    halow_test_teardown
else
    YAML_MISSING=1
    echo "  note: python3 with the yaml module is not available; the structural schema and translation checks were SKIPPED"
fi

echo "test_config_yaml: $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed"
if [ "$HALOW_TEST_FAILURES" -ne 0 ]; then exit 1; fi
if [ "${YAML_MISSING:-0}" = "1" ]; then
    echo "SKIPPED: python3 with the yaml module is required for the structural checks (a skip is not a pass)"
    exit 77
fi
exit 0
