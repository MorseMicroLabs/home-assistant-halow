#!/usr/bin/env bash
# Radio option validation: every width x mode x good/bad channel, the distinct reasons and
# the option named on the first output line.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh
. ./helpers_radio.sh

echo "== test_radio_validate =="
radio_setup

# check <expected rc> <expected option or -> <reason substring or -> <msg> <args...>
check() {
    local erc="$1" eopt="$2" ereason="$3" msg="$4"; shift 4
    local out rc first
    out="$(halow_radio_validate "$@" 2>/dev/null)"; rc=$?
    first="${out%%$'\n'*}"
    assert_eq "$erc" "$rc" "$msg: exit code"
    if [ "$erc" -eq 0 ]; then
        assert_eq "" "$out" "$msg: prints nothing when valid"
        return
    fi
    case "$first" in "OPTION=$eopt REASON="*) r=0 ;; *) r=1 ;; esac
    assert_eq "0" "$r" "$msg: first line names option $eopt ($first)"
    case "$first" in *"$ereason"*) r=0 ;; *) r=1 ;; esac
    assert_eq "0" "$r" "$msg: reason mentions '$ereason'"
}

for bw in 1 2 4 8; do
    set -- ${RADIO_EXPECT_CHANNELS[$bw]}
    good="$1"
    # every listed channel is accepted in manual mode
    all_ok=1
    for c in ${RADIO_EXPECT_CHANNELS[$bw]}; do
        halow_radio_validate AU manual "$bw" "$c" >/dev/null 2>&1 || all_ok=0
    done
    assert_eq "1" "$all_ok" "manual $bw MHz accepts every channel of its set"
    check 0 - - "manual $bw MHz channel $good" AU manual "$bw" "$good"
    # channels of the other widths (and a neighbour) are rejected
    for other in 1 2 4 8; do
        [ "$other" = "$bw" ] && continue
        set -- ${RADIO_EXPECT_CHANNELS[$other]}
        check 1 channel "not valid for $bw MHz" "manual $bw MHz rejects $other MHz channel $1" AU manual "$bw" "$1"
    done
    check 1 channel "valid channels: ${RADIO_EXPECT_CHANNELS[$bw]}" "manual $bw MHz out-of-range channel lists the valid channels" AU manual "$bw" 99
    check 1 channel "not provided" "manual $bw MHz without a channel" AU manual "$bw" ""
    check 1 channel "not provided" "manual $bw MHz with an unset ('null') channel" AU manual "$bw" null
    check 1 channel "not a whole number" "manual $bw MHz with a non-integer channel" AU manual "$bw" 43.5
    check 1 channel "not a whole number" "manual $bw MHz with a negative channel" AU manual "$bw" -43
    check 1 channel "not a whole number" "manual $bw MHz with a leading-zero channel" AU manual "$bw" 043
    # automatic: any channel value is ignored
    check 0 - - "automatic $bw MHz without a channel" AU automatic "$bw" ""
    check 0 - - "automatic $bw MHz ignores a channel from another width" AU automatic "$bw" 31
    check 0 - - "automatic $bw MHz ignores garbage in channel" AU automatic "$bw" 'x;rm -rf /'
done

# Explicit accept/reject matrix for the 802.11-2024 AU channels, written out by hand (not
# derived from the profile): a channel is valid only at the width that owns it.
for ch in $(seq 20 58); do
    owner=""
    for w in 1 2 4 8; do
        for c in ${RADIO_EXPECT_CHANNELS[$w]}; do [ "$c" = "$ch" ] && owner="$w"; done
    done
    for w in 1 2 4 8; do
        if [ "$w" = "$owner" ]; then
            check 0 - - "manual $w MHz accepts its own channel $ch" AU manual "$w" "$ch"
        else
            check 1 channel "not valid for $w MHz" "manual $w MHz rejects channel $ch" AU manual "$w" "$ch"
        fi
    done
done
check 0 - - "channel 28 is valid at 1 MHz" AU manual 1 28
check 1 channel "not valid for 2 MHz" "channel 28 is not a 2 MHz channel" AU manual 2 28
check 1 channel "not valid for 4 MHz" "channel 28 is not a 4 MHz channel" AU manual 4 28
check 1 channel "not valid for 8 MHz" "channel 28 is not an 8 MHz channel" AU manual 8 28
check 1 channel "not valid for 1 MHz" "1 MHz rejects channel 43 (an 8 MHz channel)" AU manual 1 43
check 0 - - "8 MHz accepts channel 43" AU manual 8 43
check 1 channel "not valid for 8 MHz" "8 MHz rejects channel 44 (a 1 MHz channel)" AU manual 8 44
check 0 - - "1 MHz accepts channel 44" AU manual 1 44
check 1 channel "not valid for 2 MHz" "2 MHz rejects channel 42 (a 1 MHz channel)" AU manual 2 42
for w in 1 2 4 8; do
    check 1 channel "not valid for $w MHz" "channel 27 (below the AU range) is refused at $w MHz" AU manual "$w" 27
    check 1 channel "not valid for $w MHz" "channel 51 (above the AU range) is refused at $w MHz" AU manual "$w" 51
done
for old in 31 33 35 37 39 41 43 45 47 49; do
    case " ${RADIO_EXPECT_CHANNELS[1]} " in *" $old "*) continue ;; esac
    check 1 channel "not valid for 1 MHz" "the 802.11-2020 1 MHz odd channel $old is refused" AU manual 1 "$old"
done
check 1 channel "valid channels: 28 30 32 34 36 38 40 42 44 46 48 50" "the 1 MHz reason lists the 2024 set" AU manual 1 27
check 1 channel "valid channels: 29 33 37 41 45 49" "the 2 MHz reason lists the 2024 set" AU manual 2 30
check 1 channel "valid channels: 31 39 47" "the 4 MHz reason lists the 2024 set" AU manual 4 32
check 1 channel "valid channels: 35 43" "the 8 MHz reason lists the 2024 set" AU manual 8 44
check 1 bandwidth "not supported" "an unsupported bandwidth (16) is rejected in automatic mode" AU automatic 16 ""
check 1 bandwidth "not supported" "an unsupported bandwidth (3) is rejected in manual mode" AU manual 3 43
check 1 bandwidth "supported: 1 2 4 8" "the bandwidth reason lists the supported widths" AU manual 5 43
check 1 bandwidth "not supported" "a non-integer bandwidth is rejected" AU automatic "1MHz" ""
check 1 bandwidth "not supported" "an empty bandwidth is rejected" AU automatic "" ""
check 1 region "no validated radio profile" "an unknown region is rejected" US automatic 1 ""
check 1 region "no validated radio profile" "an empty region is rejected" "" manual 1 43
check 1 region "no validated radio profile" "the region is checked before the mode" XX bogus 1 43
check 1 radio_mode "unknown Channel selection mode" "an unknown mode is rejected" AU auto 1 43
check 1 radio_mode "unknown Channel selection mode" "fallback is not a customer mode" AU fallback 1 43
check 1 radio_mode "unknown Channel selection mode" "an empty mode is rejected" AU "" 1 43
check 1 bandwidth "not supported" "the bandwidth is checked before the channel" AU manual 16 abc

out="$(halow_radio_validate AU manual 1 $'43\nOPTION=region REASON=x' 2>/dev/null)"
n=0; while IFS= read -r _l; do n=$((n + 1)); done <<< "$out"
assert_eq "1" "$n" "a channel value with an embedded newline cannot inject a second line"

halow_test_teardown
radio_summary test_radio_validate
