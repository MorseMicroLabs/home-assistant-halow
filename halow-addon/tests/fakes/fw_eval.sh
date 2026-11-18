#!/usr/bin/env bash
# Packet-walk evaluator over the fake iptables state (tests/fakes/fake_iptables).
#
# THIS IS A MODEL OF THE RULE SEMANTICS, NOT PROOF OF KERNEL BEHAVIOUR. It walks the
# textual rules the fake stored, in order, for one synthetic packet described by its
# interfaces, addresses, protocol, port and connection-tracking state, and reports the
# verdict the rules would give if the kernel matched exactly as modelled here. It knows
# nothing about routing, NAT rewriting, bridge netfilter, conntrack helpers or Docker's
# real rule set (the tests install a small Docker-like rule set to stand in for it).
# Any rule element it does not understand is an evaluation error, never a silent match.
#
# Usage (after sourcing):  fw_verdict <iptables|ip6tables> <INPUT|FORWARD> key=value…
# Keys: in out src dst proto(tcp|udp|icmp|igmp|…) dport sport icmp(8|echo-request|…)
#       ctstate(comma list of NEW|ESTABLISHED|RELATED|DNAT; a DNAT'ed connection carries DNAT
#       in addition to NEW/ESTABLISHED, as in conntrack; default NEW) origdst origdport
# Prints ACCEPT or DROP (REJECT is reported as DROP); returns 2 on an evaluation error.
# FW_EVAL_TRACE holds the rules that decided, for failure messages.

declare -gA FW_PKT=()
FW_EVAL_TRACE=""
FW_EVAL_VERDICT=""

_fw_ip_to_int() {
    local a b c d x
    IFS='.' read -r a b c d x <<< "$1"
    case "$a$b$c$d" in ''|*[!0-9]*) return 1 ;; esac
    [ -n "$x" ] && return 1
    echo $(( (a << 24) | (b << 16) | (c << 8) | d ))
}

_fw_in_cidr() { # _fw_in_cidr <ip> <cidr>
    local ip="$1" cidr="$2" net p ip_i net_i mask
    case "$cidr" in */*) net="${cidr%/*}"; p="${cidr#*/}" ;; *) net="$cidr"; p=32 ;; esac
    ip_i="$(_fw_ip_to_int "$ip")" || return 2
    net_i="$(_fw_ip_to_int "$net")" || return 2
    if [ "$p" -eq 0 ]; then mask=0; else mask=$(( (0xFFFFFFFF << (32 - p)) & 0xFFFFFFFF )); fi
    [ $(( ip_i & mask )) -eq $(( net_i & mask )) ]
}

_fw_iface_match() { # _fw_iface_match <pkt_iface> <pattern>
    local v="$1" pat="$2"
    case "$pat" in
        *+) [ -n "$v" ] && [ "${v#"${pat%+}"}" != "$v" ] ;;
        *) [ "$v" = "$pat" ] ;;
    esac
}

_fw_icmp_num() {
    case "$1" in
        echo-request) echo 8 ;; echo-reply) echo 0 ;; destination-unreachable) echo 3 ;;
        time-exceeded) echo 11 ;; *) echo "$1" ;;
    esac
}

# _fw_rule_match <rule text> — 0 match, 1 no match, 2 error. Sets _FW_TARGET.
_fw_rule_match() {
    local -a w
    read -r -a w <<< "$1"
    local k=0 m=${#w[@]} neg=0 tok val res list item found
    _FW_TARGET=""
    local matched=0
    while [ "$k" -lt "$m" ]; do
        tok="${w[$k]}"
        if [ "$tok" = "!" ]; then neg=1; k=$((k + 1)); continue; fi
        val="${w[$((k + 1))]:-}"
        res=0
        case "$tok" in
            -i) _fw_iface_match "${FW_PKT[in]:-}" "$val" || res=1 ;;
            -o) _fw_iface_match "${FW_PKT[out]:-}" "$val" || res=1 ;;
            -s|-d)
                if [ "$tok" = "-s" ]; then item="${FW_PKT[src]:-}"; else item="${FW_PKT[dst]:-}"; fi
                if [ -z "$item" ]; then echo "fw_eval: packet has no address for $tok" >&2; return 2; fi
                if _fw_in_cidr "$item" "$val"; then res=0; else res=$?; fi
                if [ "$res" -eq 2 ]; then return 2; fi
                ;;
            -p) [ "$val" = "all" ] || [ "${FW_PKT[proto]:-}" = "$val" ] || res=1 ;;
            -m) ;;
            --dport) [ "${FW_PKT[dport]:-}" = "$val" ] || res=1 ;;
            --sport) [ "${FW_PKT[sport]:-}" = "$val" ] || res=1 ;;
            --icmp-type) [ "$(_fw_icmp_num "${FW_PKT[icmp]:-}")" = "$(_fw_icmp_num "$val")" ] || res=1 ;;
            --ctstate)
                # the packet's connection state is a set (e.g. ESTABLISHED,DNAT); the rule matches
                # when any listed state is in it (iptables conntrack --ctstate semantics)
                found=1
                IFS=',' read -r -a list <<< "$val"
                IFS=',' read -r -a have <<< "${FW_PKT[ctstate]:-NEW}"
                for x in "${list[@]}"; do for item in "${have[@]}"; do if [ "$x" = "$item" ]; then found=0; fi; done; done
                res=$found
                ;;
            --ctorigdst)
                if [ -z "${FW_PKT[origdst]:-}" ]; then res=1
                elif _fw_in_cidr "${FW_PKT[origdst]}" "$val"; then res=0
                else res=$?; if [ "$res" -eq 2 ]; then return 2; fi
                fi
                ;;
            --ctorigdstport) [ "${FW_PKT[origdport]:-}" = "$val" ] || res=1 ;;
            --comment) ;;
            -j) _FW_TARGET="$val" ;;
            *) echo "fw_eval: unsupported rule element '$tok' in: $1" >&2; return 2 ;;
        esac
        if [ "$tok" != "-j" ] && [ "$tok" != "-m" ] && [ "$tok" != "--comment" ]; then
            if [ "$neg" -eq 1 ]; then res=$(( 1 - res )); fi
            if [ "$res" -ne 0 ]; then matched=1; fi
        fi
        neg=0
        k=$((k + 2))
    done
    if [ -z "$_FW_TARGET" ]; then echo "fw_eval: rule without a target: $1" >&2; return 2; fi
    return "$matched"
}

# _fw_walk <tdir> <chain> <depth> — 0 terminal verdict set; 1 fell off the end;
# 3 RETURN; 2 error.
_fw_walk() {
    local tdir="$1" chain="$2" depth="$3" rule n=0 rc target
    [ "$depth" -gt 16 ] && { echo "fw_eval: chain depth exceeded" >&2; return 2; }
    [ -f "$tdir/rules.$chain" ] || { echo "fw_eval: no chain $chain" >&2; return 2; }
    local -a rules=()
    mapfile -t rules < "$tdir/rules.$chain"
    for rule in "${rules[@]}"; do
        n=$((n + 1))
        if _fw_rule_match "$rule"; then rc=0; else rc=$?; fi
        if [ "$rc" -eq 2 ]; then return 2; fi
        if [ "$rc" -ne 0 ]; then continue; fi
        target="$_FW_TARGET"
        case "$target" in
            ACCEPT|DROP|REJECT)
                FW_EVAL_VERDICT="$target"
                FW_EVAL_TRACE="${FW_EVAL_TRACE}${chain}#${n}: ${rule}; "
                return 0 ;;
            RETURN) return 3 ;;
            LOG) continue ;;
            MASQUERADE|DNAT|SNAT) echo "fw_eval: nat target $target not modelled" >&2; return 2 ;;
            *)
                FW_EVAL_TRACE="${FW_EVAL_TRACE}${chain}#${n} -> ${target}; "
                if _fw_walk "$tdir" "$target" $((depth + 1)); then rc=0; else rc=$?; fi
                case "$rc" in 0) return 0 ;; 2) return 2 ;; esac
                ;;
        esac
    done
    return 1
}

fw_verdict() {
    local name="$1" hook="$2" kv rc tdir
    shift 2
    FW_PKT=()
    for kv in "$@"; do FW_PKT["${kv%%=*}"]="${kv#*=}"; done
    FW_EVAL_TRACE=""; FW_EVAL_VERDICT=""
    tdir="${HALOW_FAKE_FW_DIR:?}/state/$name/filter"
    if _fw_walk "$tdir" "$hook" 0; then rc=0; else rc=$?; fi
    case "$rc" in
        0) ;;
        1|3) FW_EVAL_VERDICT="$(cat "$tdir/policy.$hook")"; FW_EVAL_TRACE="${FW_EVAL_TRACE}policy ${FW_EVAL_VERDICT}" ;;
        *) echo "ERROR"; return 2 ;;
    esac
    if [ "$FW_EVAL_VERDICT" = "REJECT" ]; then FW_EVAL_VERDICT=DROP; fi
    echo "$FW_EVAL_VERDICT"
}
