#!/usr/bin/env bash
# halow: the add-on's own firewall chains (selective policy with client isolation and a
# customer allow-list).
#
# Three add-on-named filter chains per address family, plus one NAT chain:
#
#   HALOW-IN       hooked at INPUT position 1 by "-i <bridge>": traffic from HaLow clients
#                  to the host itself. Accepts DHCP (udp 67, broadcast and unicast
#                  renewals to the gateway), DNS (udp/tcp 53) and ICMP echo to the gateway
#                  address only, established replies and ICMP errors related to them, the
#                  allow-listed host ports on the gateway address; drops everything else
#                  (including multicast discovery and IGMP).
#   HALOW-FWD-OUT  hooked at position 1 of DOCKER-USER (FORWARD when DOCKER-USER does not
#                  exist) by "-i <bridge>": forwarded traffic from HaLow clients. Accepts
#                  established replies and related ICMP errors (replies to sessions that
#                  the host's containers opened towards HaLow devices), allow-listed
#                  Docker-published ports reached through the gateway address (matched on
#                  the conntrack DNAT status and original destination, so an unpublished
#                  container port is never admitted), and the HaLow subnet towards the
#                  uplink (the NAT'd LAN and Internet path); drops everything else (Docker
#                  networks, other interfaces, other HaLow ports, spoofed sources).
#   HALOW-FWD-IN   hooked immediately after the OUT jump by "-o <bridge>": forwarded
#                  traffic to HaLow devices. Accepts established replies and related ICMP
#                  errors, and new connections from the Supervisor's Docker network
#                  (HALOW_HASSIO_IFACE); drops everything else (new connections from the
#                  customer LAN through the uplink, from other Docker networks, ...).
#   HALOW-PARENT   a single terminal DROP, hooked at INPUT position 2 and at position 3 of
#                  the forwarding hook by "-i <parent>+" (the radio's parent interface and
#                  every per-station interface named after it): a radio interface that is
#                  not, or not yet, a port of the bridge is never ungoverned. Traffic that
#                  enters through the bridge is seen on the bridge, not on its ports, so
#                  it meets the chains above first. Installed when the parent interface
#                  is given.
#   HALOW-NAT      nat table, hooked at POSTROUTING position 1: masquerades the HaLow
#                  subnet towards the uplink. Installed after the filter chains.
#
# IPv6 has the deliberately narrower equivalent: HALOW-IN6, HALOW-FWD-OUT6,
# HALOW-FWD-IN6 and HALOW-PARENT6, hooked at the same points, each a single terminal DROP
# (HaLow clients get no IPv6 connectivity at all). These chains are the second IPv6
# layer; the first is IPv6 switched off on the add-on's interfaces (ipv6.sh).
#
# Connections that Home Assistant itself (and add-ons using the host network) open
# towards HaLow devices leave through OUTPUT, which these chains do not filter; their
# replies are accepted as established by HALOW-IN.
#
# Safety properties:
#   * a chain is populated completely before its jump is installed;
#   * an existing chain is rebuilt behind a terminal guard rule inserted at its top, so it
#     never passes traffic ungoverned while it is rebuilt;
#   * a jump is inserted only when it is not already in place; re-assertion inserts the
#     new jump first and deletes stale duplicates afterwards (never a gap);
#   * removal deletes every jump to the add-on's chains first (in any chain, so both hook
#     locations are covered whatever was recorded), then flushes and deletes the chains,
#     and verifies the absence of each from the host;
#   * the ownership markers fw_filter and fw_nat are written before the change and
#     cleared only after removal is confirmed;
#   * no built-in chain is flushed, no policy is changed, no foreign rule is touched, and
#     net.ipv4.ip_forward is never written;
#   * the one built-in chain removal ever made is the INPUT base chain this add-on itself
#     created (iptables-nft creates it implicitly with the first rule): it is recorded first
#     (fw_created_input4/6), and deleted only once every add-on rule and jump is gone and it
#     is exactly the empty accept base chain; one that existed before, or that cannot be
#     shown to be this add-on's creation, is never removed.
#
# Unverified on the target device (awaiting live validation): the name and address range
# of the Supervisor's Docker network, whether DOCKER-USER exists, the hook positions after
# a Docker restart, the conntrack DNAT/original-destination matches, and the position of
# the NAT jump relative to Docker's own masquerading.
#
# Defines functions and constants only; nothing runs when sourced. Depends on common.sh,
# ownership.sh, validate.sh, allowlist.sh and uplink.sh.

# The Supervisor's Docker network bridge interface. Its name (and address range) on the
# target device awaits live validation.
: "${HALOW_HASSIO_IFACE:=hassio}"
# Docker's documented first-evaluated forwarding hook.
: "${HALOW_FW_DOCKER_HOOK:=DOCKER-USER}"
# Bound for every repeat-until-absent loop.
: "${HALOW_FW_MAX_ITER:=64}"
# The catch-all chain for the radio's own interfaces (IPv6: the same name with a 6).
: "${HALOW_FW_CHAIN_PARENT:=HALOW-PARENT}"
# Seconds iptables waits for the xtables lock before giving up (never an unbounded wait).
: "${HALOW_FW_LOCK_WAIT_S:=5}"
# The nft binary, used only to read whether the INPUT base chain exists (see "the INPUT base
# chain" below); never to change anything.
: "${HALOW_NFT:=nft}"

# --- low-level helpers -------------------------------------------------------------

# _halow_fw_run <4|6> <args…> — the selected binary, always with a bounded lock wait
# (-w <seconds>), so a lock held elsewhere cannot hang the caller.
_halow_fw_run() {
    local fam="$1" bin
    shift
    if [ "$fam" = "6" ]; then bin="${HALOW_IP6TABLES:-ip6tables}"; else bin="${HALOW_IPTABLES:-iptables}"; fi
    "$bin" -w "$HALOW_FW_LOCK_WAIT_S" "$@"
}

# _halow_fw_name <4|6> <IN|OUT|FIN|PAR|NAT> — the chain name for the family.
_halow_fw_name() {
    local fam="$1" kind="$2" name
    case "$kind" in
        IN) name="$HALOW_FW_CHAIN_IN" ;;
        OUT) name="$HALOW_FW_CHAIN_FWD_OUT" ;;
        FIN) name="$HALOW_FW_CHAIN_FWD_IN" ;;
        PAR) name="$HALOW_FW_CHAIN_PARENT" ;;
        NAT) name="$HALOW_FW_CHAIN_NAT" ;;
        *) return 1 ;;
    esac
    if [ "$fam" = "6" ]; then name="${name}6"; fi
    printf '%s\n' "$name"
}

# _halow_fw_list <4|6> <table> [<chain>] — prints the -S listing.
_halow_fw_list() {
    local fam="$1" table="$2"
    shift 2
    _halow_fw_run "$fam" -t "$table" -S "$@" 2>/dev/null
}

# _halow_fw_has_chain <listing> <chain>
_halow_fw_has_chain() {
    local l
    while IFS= read -r l; do
        if [ "$l" = "-N $2" ] || [ "$l" = "-P $2 ACCEPT" ] || [ "$l" = "-P $2 DROP" ]; then return 0; fi
    done <<< "$1"
    return 1
}

# _halow_fw_rules_of <listing> <chain> — prints the rule specs of <chain>, in order.
_halow_fw_rules_of() {
    local l
    while IFS= read -r l; do
        case "$l" in "-A $2 "*) printf '%s\n' "${l#"-A $2 "}" ;; esac
    done <<< "$1"
    return 0
}

# _halow_fw_target <spec> — prints the jump target of a rule spec (empty if none).
_halow_fw_target() {
    local -a w
    local k=0
    read -r -a w <<< "$1"
    while [ "$k" -lt "${#w[@]}" ]; do
        if [ "${w[$k]}" = "-j" ]; then printf '%s\n' "${w[$((k + 1))]:-}"; return 0; fi
        k=$((k + 1))
    done
    return 0
}

# _halow_fw_jumps <listing> <target…> — prints "<chain>|<index>|<spec>" for every rule
# whose jump target is one of <target…>, in listing order (index is 1-based per chain).
_halow_fw_jumps() {
    local listing="$1" l chain spec t prev=""
    shift
    local -A idx=()
    while IFS= read -r l; do
        case "$l" in "-A "*) ;; *) continue ;; esac
        spec="${l#-A }"
        chain="${spec%% *}"
        spec="${spec#* }"
        idx[$chain]=$(( ${idx[$chain]:-0} + 1 ))
        t="$(_halow_fw_target "$spec")"
        for prev in "$@"; do
            if [ "$t" = "$prev" ]; then printf '%s|%s|%s\n' "$chain" "${idx[$chain]}" "$spec"; break; fi
        done
    done <<< "$listing"
    return 0
}

# _halow_fw_exec_spec <4|6> <table> <op> <chain> [<num>] <spec> — runs one iptables
# operation with <spec> word-split into arguments (specs never contain whitespace inside
# a value: every value is validated first).
_halow_fw_exec_spec() {
    local fam="$1" table="$2" op="$3" chain="$4" num="$5" spec="$6"
    local -a w
    read -r -a w <<< "$spec"
    if [ -n "$num" ]; then
        _halow_fw_run "$fam" -t "$table" "$op" "$chain" "$num" "${w[@]}"
    else
        _halow_fw_run "$fam" -t "$table" "$op" "$chain" "${w[@]}"
    fi
}

# _halow_fw_delete_at <4|6> <table> <chain> <index> <spec> — deletes rule <index> of
# <chain> only if it still is <spec> (re-read immediately before deleting).
_halow_fw_delete_at() {
    local fam="$1" table="$2" chain="$3" i="$4" spec="$5" cur
    if cur="$(_halow_fw_list "$fam" "$table" "$chain" "$i")"; then :; else return 1; fi
    if [ "$cur" != "-A $chain $spec" ]; then
        halow_log_warning "firewall: rule $i of $chain changed before it could be removed; will retry"
        return 1
    fi
    _halow_fw_run "$fam" -t "$table" -D "$chain" "$i"
}

# --- rule sets ---------------------------------------------------------------------

# _halow_fw_rules <4|6> <IN|OUT|FIN> <bridge> <net> <gw> <uplink> <entries> — prints the
# chain's rule specs, one per line, in order.
_halow_fw_rules() {
    local fam="$1" kind="$2" bridge="$3" net="$4" gw="$5" uplink="$6" entries="$7" e proto port
    if [ "$fam" = "6" ]; then
        printf '%s\n' "-j DROP"
        return 0
    fi
    case "$kind" in
        IN)
            printf '%s\n' "-d 255.255.255.255/32 -p udp -m udp --dport 67 -j ACCEPT"
            printf '%s\n' "-d ${gw}/32 -p udp -m udp --dport 67 -j ACCEPT"
            printf '%s\n' "-d ${gw}/32 -p udp -m udp --dport 53 -j ACCEPT"
            printf '%s\n' "-d ${gw}/32 -p tcp -m tcp --dport 53 -j ACCEPT"
            printf '%s\n' "-d ${gw}/32 -p icmp -m icmp --icmp-type 8 -j ACCEPT"
            printf '%s\n' "-m conntrack --ctstate ESTABLISHED -j ACCEPT"
            printf '%s\n' "-p icmp -m conntrack --ctstate RELATED -j ACCEPT"
            while IFS= read -r e; do
                [ -z "$e" ] && continue
                proto="${e%%/*}"; port="${e#*/}"
                printf '%s\n' "-d ${gw}/32 -p ${proto} -m ${proto} --dport ${port} -j ACCEPT"
            done <<< "$entries"
            printf '%s\n' "-j DROP"
            ;;
        OUT)
            printf '%s\n' "-m conntrack --ctstate ESTABLISHED -j ACCEPT"
            printf '%s\n' "-p icmp -m conntrack --ctstate RELATED -j ACCEPT"
            while IFS= read -r e; do
                [ -z "$e" ] && continue
                proto="${e%%/*}"; port="${e#*/}"
                printf '%s\n' "-o ${HALOW_HASSIO_IFACE} -p ${proto} -m conntrack --ctstate DNAT --ctorigdst ${gw}/32 --ctorigdstport ${port} -j ACCEPT"
            done <<< "$entries"
            printf '%s\n' "-s ${net} -o ${uplink} -j ACCEPT"
            printf '%s\n' "-j DROP"
            ;;
        FIN)
            printf '%s\n' "-m conntrack --ctstate ESTABLISHED -j ACCEPT"
            printf '%s\n' "-p icmp -m conntrack --ctstate RELATED -j ACCEPT"
            printf '%s\n' "-i ${HALOW_HASSIO_IFACE} -m conntrack --ctstate NEW -j ACCEPT"
            printf '%s\n' "-j DROP"
            ;;
        PAR)
            printf '%s\n' "-j DROP"
            ;;
        *) return 1 ;;
    esac
}

# --- building blocks ---------------------------------------------------------------

# _halow_fw_populate <4|6> <table> <chain> <guard_target> <rules> — makes <chain> hold
# exactly <rules> (newline-separated). A new chain is created and filled (it has no jump
# yet). An existing chain is rebuilt behind a guard rule (-j <guard_target>) inserted at
# its top first and removed last, so it never passes traffic ungoverned meanwhile.
_halow_fw_populate() {
    local fam="$1" table="$2" chain="$3" guard="$4" rules="$5" listing cur r count want i last
    if listing="$(_halow_fw_list "$fam" "$table")"; then :; else
        halow_log_error "firewall: cannot list the $table table (IPv$fam)"
        return 1
    fi
    local rebuilt=0
    if _halow_fw_has_chain "$listing" "$chain"; then
        rebuilt=1
        if ! _halow_fw_run "$fam" -t "$table" -I "$chain" 1 -j "$guard"; then return 1; fi
        if cur="$(_halow_fw_list "$fam" "$table" "$chain")"; then :; else return 1; fi
        count=0
        while IFS= read -r r; do [ -n "$r" ] && count=$((count + 1)); done <<< "$(_halow_fw_rules_of "$cur" "$chain")"
        i="$count"
        while [ "$i" -ge 2 ]; do
            if ! _halow_fw_run "$fam" -t "$table" -D "$chain" "$i"; then return 1; fi
            i=$((i - 1))
        done
    else
        if ! _halow_fw_run "$fam" -t "$table" -N "$chain"; then return 1; fi
    fi
    want=0
    while IFS= read -r r; do
        [ -z "$r" ] && continue
        if ! _halow_fw_exec_spec "$fam" "$table" -A "$chain" "" "$r"; then return 1; fi
        want=$((want + 1)); last="$r"
    done <<< "$rules"
    if [ "$rebuilt" -eq 1 ]; then
        if cur="$(_halow_fw_list "$fam" "$table" "$chain" 1)"; then :; else return 1; fi
        if [ "$cur" != "-A $chain -j $guard" ]; then
            halow_log_error "firewall: the rebuild guard of $chain is not where it was placed"
            return 1
        fi
        if ! _halow_fw_run "$fam" -t "$table" -D "$chain" 1; then return 1; fi
    fi
    # Verify the result: rule count, and (in the filter table) the terminal drop last.
    if cur="$(_halow_fw_list "$fam" "$table" "$chain")"; then :; else return 1; fi
    count=0; r=""
    while IFS= read -r i; do
        [ -z "$i" ] && continue
        count=$((count + 1)); r="$i"
    done <<< "$(_halow_fw_rules_of "$cur" "$chain")"
    if [ "$count" -ne "$want" ]; then
        halow_log_error "firewall: $chain holds $count rules after population, expected $want"
        return 1
    fi
    if [ "$table" = "filter" ] && [ "$r" != "-j DROP" ]; then
        halow_log_error "firewall: $chain does not end in its terminal drop"
        return 1
    fi
    return 0
}

# _halow_fw_place <4|6> <table> <chain> <pos> <spec> — makes rule <pos> of <chain> be
# <spec>: if it is not already there, the jump is checked (-C), inserted at <pos>, and
# only then are stale duplicates of it in <chain> deleted.
_halow_fw_place() {
    local fam="$1" table="$2" chain="$3" pos="$4" spec="$5" cur n i
    local -a R=()
    if cur="$(_halow_fw_list "$fam" "$table" "$chain")"; then :; else
        halow_log_error "firewall: cannot list $chain (IPv$fam)"
        return 1
    fi
    mapfile -t R < <(_halow_fw_rules_of "$cur" "$chain")
    n="${#R[@]}"
    if [ "$n" -ge "$pos" ] && [ "${R[$((pos - 1))]}" = "$spec" ]; then
        :
    else
        if [ "$pos" -gt $((n + 1)) ]; then pos=$((n + 1)); fi
        if _halow_fw_exec_spec "$fam" "$table" -C "$chain" "" "$spec" 2>/dev/null; then
            halow_log_info "firewall: re-asserting the position of a jump in $chain (IPv$fam)"
        fi
        if ! _halow_fw_exec_spec "$fam" "$table" -I "$chain" "$pos" "$spec"; then
            halow_log_error "firewall: could not insert a jump into $chain (IPv$fam)"
            return 1
        fi
        if cur="$(_halow_fw_list "$fam" "$table" "$chain")"; then :; else return 1; fi
        mapfile -t R < <(_halow_fw_rules_of "$cur" "$chain")
        n="${#R[@]}"
    fi
    i="$n"
    while [ "$i" -ge 1 ]; do
        if [ "$i" -ne "$pos" ] && [ "${R[$((i - 1))]}" = "$spec" ]; then
            if ! _halow_fw_delete_at "$fam" "$table" "$chain" "$i" "$spec"; then return 1; fi
        fi
        i=$((i - 1))
    done
    return 0
}

# _halow_fw_sweep <4|6> <table> <keep> <target…> — deletes every jump to <target…> in
# any chain except the "<chain>|<index>|<spec>" entries listed (newline-separated) in
# <keep>. Deletes from the end of each chain so indices stay valid.
_halow_fw_sweep() {
    local fam="$1" table="$2" keep="$3" listing jumps line k
    shift 3
    if listing="$(_halow_fw_list "$fam" "$table")"; then :; else return 1; fi
    jumps="$(_halow_fw_jumps "$listing" "$@")"
    local -a J=()
    mapfile -t J <<< "$jumps"
    k="${#J[@]}"
    while [ "$k" -ge 1 ]; do
        line="${J[$((k - 1))]}"
        k=$((k - 1))
        [ -z "$line" ] && continue
        case $'\n'"$keep"$'\n' in *$'\n'"$line"$'\n'*) continue ;; esac
        local c="${line%%|*}" rest="${line#*|}"
        if ! _halow_fw_delete_at "$fam" "$table" "$c" "${rest%%|*}" "${rest#*|}"; then return 1; fi
    done
    return 0
}

# _halow_fw_hook_chain <listing> — DOCKER-USER when it exists, else FORWARD.
_halow_fw_hook_chain() {
    if _halow_fw_has_chain "$1" "$HALOW_FW_DOCKER_HOOK"; then
        printf '%s\n' "$HALOW_FW_DOCKER_HOOK"
    else
        printf '%s\n' "FORWARD"
    fi
}

# _halow_fw_reassert_filter <4|6> <bridge> [<parent>] — the filter jumps in place (INPUT
# position 1; OUT at position 1 and IN at position 2 of the forwarding hook; with a parent,
# the catch-all at INPUT position 2 and hook position 3), every other jump to the add-on's
# filter chains removed afterwards. 1 if a chain is missing or a step fails.
_halow_fw_reassert_filter() {
    local fam="$1" bridge="$2" parent="${3:-}" listing in out fin par hook c keep
    if listing="$(_halow_fw_list "$fam" filter)"; then :; else
        halow_log_error "firewall: cannot list the filter table (IPv$fam)"
        return 1
    fi
    in="$(_halow_fw_name "$fam" IN)"; out="$(_halow_fw_name "$fam" OUT)"; fin="$(_halow_fw_name "$fam" FIN)"
    par="$(_halow_fw_name "$fam" PAR)"
    local -a chains=("$in" "$out" "$fin")
    if [ -n "$parent" ]; then chains+=("$par"); fi
    for c in "${chains[@]}"; do
        if ! _halow_fw_has_chain "$listing" "$c"; then
            halow_log_error "firewall: chain $c is missing (IPv$fam); a jump to it is not installed"
            return 1
        fi
    done
    hook="$(_halow_fw_hook_chain "$listing")"
    _halow_fw_place "$fam" filter INPUT 1 "-i ${bridge} -j ${in}" || return 1
    _halow_fw_place "$fam" filter "$hook" 1 "-i ${bridge} -j ${out}" || return 1
    _halow_fw_place "$fam" filter "$hook" 2 "-o ${bridge} -j ${fin}" || return 1
    keep="INPUT|1|-i ${bridge} -j ${in}
${hook}|1|-i ${bridge} -j ${out}
${hook}|2|-o ${bridge} -j ${fin}"
    if [ -n "$parent" ]; then
        _halow_fw_place "$fam" filter INPUT 2 "-i ${parent}+ -j ${par}" || return 1
        _halow_fw_place "$fam" filter "$hook" 3 "-i ${parent}+ -j ${par}" || return 1
        keep="${keep}
INPUT|2|-i ${parent}+ -j ${par}
${hook}|3|-i ${parent}+ -j ${par}"
        _halow_fw_sweep "$fam" filter "$keep" "$in" "$out" "$fin" "$par" || return 1
    else
        _halow_fw_sweep "$fam" filter "$keep" "$in" "$out" "$fin" || return 1
    fi
    return 0
}

# --- the INPUT base chain -----------------------------------------------------------
# On a host whose iptables is iptables-nft, the front end always LISTS the built-in chains
# (-S prints "-P INPUT ACCEPT" whether or not the nf_tables base chain exists), and the
# first rule inserted into INPUT silently creates the base chain. A host that never used
# INPUT therefore gains an empty "type filter hook input priority filter; policy accept"
# chain, left behind after every add-on rule and jump is gone. That one creation is this
# add-on's, so it is recorded (marker fw_created_input4 / fw_created_input6, written
# BEFORE the first insertion so a crash leaves the claim on record) and undone at removal,
# and only that: a base chain that already existed is never claimed. The only way to tell
# "absent" from "present and empty" is nft itself (HALOW_NFT); without it, or when it cannot
# read the chain, ownership of a creation cannot be established, so nothing is claimed and
# the chain is never removed (fail closed).

# _halow_fw_created_key <4|6> — the marker that records this add-on created INPUT.
_halow_fw_created_key() {
    printf 'fw_created_input%s\n' "$1"
}

# _halow_fw_input_state <4|6> — prints the state of the nf_tables base chain INPUT of the
# filter table: absent; empty (exactly the empty accept base chain
# "type filter hook input priority filter; policy accept;" and nothing else); other (it
# exists with rules, another policy or another definition); unknown (nft missing or the
# chain cannot be read).
_halow_fw_input_state() {
    local fam="$1" nft="${HALOW_NFT:-nft}" nfam out l norm=""
    if [ "$fam" = "6" ]; then nfam=ip6; else nfam=ip; fi
    if ! command -v "$nft" >/dev/null 2>&1; then
        printf 'unknown\n'
        return 0
    fi
    if out="$("$nft" list chain "$nfam" filter INPUT 2>&1)"; then :; else
        case "$out" in
            *"No such file or directory"*) printf 'absent\n' ;;
            *) printf 'unknown\n' ;;
        esac
        return 0
    fi
    while IFS= read -r l; do
        l="${l#"${l%%[![:space:]]*}"}"
        l="${l%"${l##*[![:space:]]}"}"
        [ -n "$l" ] && norm="${norm:+$norm }$l"
    done <<< "$out"
    case "$norm" in
        "table $nfam filter { chain INPUT { type filter hook input priority filter; policy accept; } }" \
        | "table $nfam filter { chain INPUT { type filter hook input priority 0; policy accept; } }")
            printf 'empty\n' ;;
        *) printf 'other\n' ;;
    esac
}

# _halow_fw_claim_input <4|6> — before the first insertion into INPUT: records that this
# add-on is about to create the base chain, but only when the host shows it absent. 1
# (logged) if that record cannot be written (nothing may be inserted then).
_halow_fw_claim_input() {
    local fam="$1" key st
    key="$(_halow_fw_created_key "$fam")"
    if halow_own_check "$key"; then return 0; fi   # an earlier claim (retry, or after a crash) stands
    st="$(_halow_fw_input_state "$fam")"
    case "$st" in
        absent)
            if ! halow_own_mark "$key" "table=filter chain=INPUT"; then
                halow_log_error "firewall: could not record the creation of the INPUT base chain (IPv$fam); nothing installed"
                return 1
            fi
            halow_log_info "firewall: the INPUT base chain (IPv$fam) does not exist yet; its creation by the first rule is recorded as this add-on's"
            ;;
        empty|other)
            halow_log_info "firewall: the INPUT base chain (IPv$fam) already exists; it is the host's and is never removed"
            ;;
        *)
            halow_log_warning "firewall: whether the INPUT base chain (IPv$fam) exists cannot be established (nft unavailable or unreadable); its creation is not claimed and it is never removed"
            ;;
    esac
    return 0
}

# _halow_fw_release_input <4|6> — at removal, after every add-on rule and jump is gone:
# deletes the INPUT base chain when this add-on recorded its creation and it is exactly the
# empty accept base chain (nft view, and no rule and policy ACCEPT in the iptables view).
# Absent: the record is cleared. Holding anything else (the host has used it since): kept,
# the claim is dropped and logged. Deleted only if the host confirms it absent afterwards
# (the exit status of iptables is not trusted); otherwise 1 with the record kept.
_halow_fw_release_input() {
    local fam="$1" key st listing l n=0 pol=""
    key="$(_halow_fw_created_key "$fam")"
    halow_own_check "$key" || return 0
    st="$(_halow_fw_input_state "$fam")"
    case "$st" in
        absent)
            halow_own_clear "$key"
            halow_log_info "firewall: the INPUT base chain (IPv$fam) is already absent; its creation record is cleared"
            return 0 ;;
        empty) ;;
        other)
            halow_own_clear "$key"
            halow_log_warning "firewall: the INPUT base chain (IPv$fam) now holds rules, another policy or another definition; it is left in place and no longer claimed"
            return 0 ;;
        *)
            halow_log_error "firewall: the INPUT base chain (IPv$fam) cannot be read; its removal is unconfirmed and its creation record is kept"
            return 1 ;;
    esac
    if listing="$(_halow_fw_list "$fam" filter INPUT)"; then :; else
        halow_log_error "firewall: cannot list INPUT (IPv$fam); its removal is unconfirmed"
        return 1
    fi
    while IFS= read -r l; do
        case "$l" in "-A INPUT "*) n=$((n + 1)) ;; "-P INPUT "*) pol="${l#-P INPUT }" ;; esac
    done <<< "$listing"
    if [ "$n" -ne 0 ] || [ "$pol" != "ACCEPT" ]; then
        halow_own_clear "$key"
        halow_log_warning "firewall: the INPUT base chain (IPv$fam) is not empty with policy ACCEPT in the iptables view; it is left in place and no longer claimed"
        return 0
    fi
    _halow_fw_run "$fam" -t filter -X INPUT || true
    if [ "$(_halow_fw_input_state "$fam")" = "absent" ]; then
        halow_own_clear "$key"
        halow_log_info "firewall: the INPUT base chain (IPv$fam), created by this add-on, is removed"
        return 0
    fi
    halow_log_error "firewall: the INPUT base chain (IPv$fam) is still present after its removal; creation record kept for a retry"
    return 1
}

# _halow_fw_marker_field <bridge|parent> — the value recorded for <field> in the fw_filter
# marker (one "key=value" per line); empty if none.
_halow_fw_marker_field() {
    local want="$1" line
    while IFS= read -r line; do
        case "$line" in "${want}="*) printf '%s' "${line#"${want}="}"; return 0 ;; esac
    done <<< "$(halow_own_get fw_filter)"
    return 0
}

# _halow_fw_remove_chains <4|6> <table> <chain…> — every jump to <chain…> removed first
# (each deleted repeatedly until -C reports it absent; the whole table is re-read until no
# jump remains), then the chains flushed and deleted, then absence verified.
_halow_fw_remove_chains() {
    local fam="$1" table="$2" listing jumps line c spec iter=0 k t
    shift 2
    while :; do
        if listing="$(_halow_fw_list "$fam" "$table")"; then :; else
            halow_log_error "firewall: cannot list the $table table (IPv$fam); removal unconfirmed"
            return 1
        fi
        jumps="$(_halow_fw_jumps "$listing" "$@")"
        local pending=""
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            c="${line%%|*}"
            case " $* " in *" $c "*) continue ;; esac   # rules inside our own chains go with the flush
            pending="${pending}${line}"$'\n'
        done <<< "$jumps"
        [ -z "$pending" ] && break
        iter=$((iter + 1))
        if [ "$iter" -gt "$HALOW_FW_MAX_ITER" ]; then
            halow_log_error "firewall: jumps to the add-on chains keep reappearing (IPv$fam $table); removal unconfirmed"
            return 1
        fi
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            c="${line%%|*}"; spec="${line#*|}"; spec="${spec#*|}"
            case "$spec" in
                *\"*|*\'*)
                    halow_log_error "firewall: a jump in $c cannot be reproduced for deletion; removal unconfirmed"
                    return 1 ;;
            esac
            k=0
            while _halow_fw_exec_spec "$fam" "$table" -C "$c" "" "$spec" 2>/dev/null; do
                _halow_fw_exec_spec "$fam" "$table" -D "$c" "" "$spec" || break
                k=$((k + 1))
                if [ "$k" -ge "$HALOW_FW_MAX_ITER" ]; then break; fi
            done
        done <<< "$pending"
    done
    for t in "$@"; do
        if _halow_fw_has_chain "$listing" "$t"; then
            _halow_fw_run "$fam" -t "$table" -F "$t" || true
            _halow_fw_run "$fam" -t "$table" -X "$t" || true
        fi
    done
    if listing="$(_halow_fw_list "$fam" "$table")"; then :; else
        halow_log_error "firewall: cannot list the $table table (IPv$fam); removal unconfirmed"
        return 1
    fi
    for t in "$@"; do
        if _halow_fw_has_chain "$listing" "$t"; then
            halow_log_error "firewall: chain $t is still present (IPv$fam $table)"
            return 1
        fi
    done
    if [ -n "$(_halow_fw_jumps "$listing" "$@")" ]; then
        halow_log_error "firewall: a jump to an add-on chain is still present (IPv$fam $table)"
        return 1
    fi
    return 0
}

# _halow_fw_validate_common <bridge> <subnet_cidr> <uplink> — prints the network form of
# the subnet; 1 (logged) on an invalid value.
_halow_fw_validate_common() {
    local bridge="$1" subnet="$2" uplink="$3" net
    if ! halow_validate_iface_name "$bridge"; then return 1; fi
    if ! halow_validate_iface_name "$uplink"; then return 1; fi
    case "$subnet" in */*) ;; *) halow_log_error "firewall: subnet '$subnet' has no prefix length"; return 1 ;; esac
    if net="$(halow_uplink_network "$subnet")"; then :; else
        halow_log_error "firewall: subnet '$subnet' is not a valid IPv4 CIDR"
        return 1
    fi
    printf '%s\n' "$net"
}

# --- public API --------------------------------------------------------------------

# halow_fw_install_filters <bridge> <subnet_cidr> <gateway_ip> <uplink> <allow_list> [<parent_iface>]
# Writes the fw_filter marker, populates HALOW-IN/-FWD-OUT/-FWD-IN (and the IPv6
# equivalents) completely, then hooks them. With <parent_iface>, HALOW-PARENT (and
# HALOW-PARENT6) are populated and hooked too: every packet arriving on <parent_iface> or
# an interface whose name starts with it, other than through the bridge, is dropped in
# INPUT and in forwarding. Without it, a catch-all left from an earlier install is
# removed. Calling it again (for example once the parent interface is known) rebuilds and
# re-hooks without a gap. On any failure everything is removed again (the marker is kept
# if that removal cannot be confirmed) and 1 is returned.
halow_fw_install_filters() {
    local bridge="$1" subnet="$2" gw="$3" uplink="$4" allow="${5:-}" parent="${6:-}" net prefix entries out fam kind rules rec
    if net="$(_halow_fw_validate_common "$bridge" "$subnet" "$uplink")"; then :; else return 1; fi
    prefix="${net#*/}"
    if ! halow_validate_ipv4_cidr "${gw}/32" 2>/dev/null || [ "$(halow_uplink_network "${gw}/${prefix}")" != "$net" ]; then
        halow_log_error "firewall: gateway '$gw' is not an address inside $net"
        return 1
    fi
    if [ -n "$parent" ]; then
        if ! halow_validate_iface_name "$parent" || [ "${#parent}" -gt 14 ]; then
            halow_log_error "firewall: parent interface '$parent' is not a valid interface name"
            return 1
        fi
        if [ "$parent" = "$bridge" ] || [ "$parent" = "$uplink" ]; then
            halow_log_error "firewall: the parent interface must differ from the bridge and the uplink"
            return 1
        fi
        case "$uplink" in "$parent"*)
            halow_log_error "firewall: the uplink $uplink would match the catch-all for $parent; refusing"
            return 1 ;;
        esac
        case "$HALOW_HASSIO_IFACE" in "$parent"*)
            halow_log_error "firewall: the Supervisor network $HALOW_HASSIO_IFACE would match the catch-all for $parent; refusing"
            return 1 ;;
        esac
    fi
    if out="$(halow_allowlist_validate "$allow")"; then :; else
        halow_log_error "firewall: allow-list rejected: $out"
        return 1
    fi
    entries="$(halow_allowlist_entries "$allow")"
    rec="bridge=${bridge}"
    if [ -n "$parent" ]; then rec="${rec}"$'\n'"parent=${parent}"; fi
    if ! halow_own_mark fw_filter "$rec"; then
        halow_log_error "firewall: could not record ownership of the filter chains; nothing installed"
        return 1
    fi
    local ok=1
    local -a kinds=(IN OUT FIN)
    if [ -n "$parent" ]; then kinds+=(PAR); fi
    for fam in 4 6; do
        # The INPUT base chain, if absent, is created by the first insertion (reassert below):
        # its creation is recorded first.
        if ! _halow_fw_claim_input "$fam"; then ok=0; break; fi
        for kind in "${kinds[@]}"; do
            if rules="$(_halow_fw_rules "$fam" "$kind" "$bridge" "$net" "$gw" "$uplink" "$entries")"; then :; else ok=0; break; fi
            if ! _halow_fw_populate "$fam" filter "$(_halow_fw_name "$fam" "$kind")" DROP "$rules"; then ok=0; break; fi
        done
        [ "$ok" -eq 1 ] || break
        if ! _halow_fw_reassert_filter "$fam" "$bridge" "$parent"; then ok=0; break; fi
        if [ -z "$parent" ]; then
            # No catch-all requested: one left from an earlier install goes (its jumps
            # first, then the chain).
            if ! _halow_fw_remove_chains "$fam" filter "$(_halow_fw_name "$fam" PAR)"; then ok=0; break; fi
        fi
    done
    if [ "$ok" -eq 1 ]; then
        if [ -n "$parent" ]; then
            halow_log_info "firewall: filter chains installed and hooked for $bridge ($net via $uplink; catch-all for ${parent}*)"
        else
            halow_log_info "firewall: filter chains installed and hooked for $bridge ($net via $uplink)"
        fi
        return 0
    fi
    halow_log_error "firewall: installing the filter chains failed; removing what was installed"
    if halow_fw_remove_filters; then :; else
        halow_log_error "firewall: removal after the failed install is unconfirmed; ownership kept for a retry"
    fi
    return 1
}

# halow_fw_install_nat <bridge> <subnet_cidr> <uplink>
# Writes the fw_nat marker, populates HALOW-NAT, then hooks it at POSTROUTING position 1.
# Refuses (1, nothing changed) unless the IPv4 forwarding filter jumps are in place, so
# NAT is never installed before forwarding is governed.
halow_fw_install_nat() {
    local bridge="$1" subnet="$2" uplink="$3" net listing nat jumps hook
    if net="$(_halow_fw_validate_common "$bridge" "$subnet" "$uplink")"; then :; else return 1; fi
    if listing="$(_halow_fw_list 4 filter)"; then :; else
        halow_log_error "firewall: cannot list the filter table; NAT not installed"
        return 1
    fi
    hook="$(_halow_fw_hook_chain "$listing")"
    jumps="$(_halow_fw_jumps "$listing" "$(_halow_fw_name 4 OUT)")"
    case "$jumps" in "$hook|"*|*$'\n'"$hook|"*) ;; *)
        halow_log_error "firewall: the forwarding filter chains are not hooked; NAT not installed"
        return 1 ;;
    esac
    jumps="$(_halow_fw_jumps "$listing" "$(_halow_fw_name 4 FIN)")"
    case "$jumps" in "$hook|"*|*$'\n'"$hook|"*) ;; *)
        halow_log_error "firewall: the forwarding filter chains are not hooked; NAT not installed"
        return 1 ;;
    esac
    if ! halow_own_mark fw_nat "subnet=${net} uplink=${uplink}"; then
        halow_log_error "firewall: could not record ownership of the NAT chain; nothing installed"
        return 1
    fi
    nat="$(_halow_fw_name 4 NAT)"
    if _halow_fw_populate 4 nat "$nat" RETURN "-s ${net} -o ${uplink} -j MASQUERADE" \
        && _halow_fw_place 4 nat POSTROUTING 1 "-j ${nat}" \
        && _halow_fw_sweep 4 nat "POSTROUTING|1|-j ${nat}" "$nat"; then
        halow_log_info "firewall: NAT chain installed for $net via $uplink"
        return 0
    fi
    halow_log_error "firewall: installing the NAT chain failed; removing it"
    if halow_fw_remove_nat; then :; else
        halow_log_error "firewall: removal of the NAT chain is unconfirmed; ownership kept for a retry"
    fi
    return 1
}

# halow_fw_remove_nat — idempotent. 0 when HALOW-NAT and every jump to it are confirmed
# absent (the fw_nat marker is then cleared); 1 otherwise (marker kept).
halow_fw_remove_nat() {
    if _halow_fw_remove_chains 4 nat "$(_halow_fw_name 4 NAT)"; then
        halow_own_clear fw_nat
        return 0
    fi
    halow_log_error "firewall: removal of the NAT chain is unconfirmed"
    return 1
}

# halow_fw_remove_filters — idempotent. 0 when every add-on filter chain and every jump to
# one is confirmed absent for IPv4 and IPv6, and an INPUT base chain this add-on created is
# removed again (the fw_filter marker is then cleared); 1 otherwise (marker kept).
halow_fw_remove_filters() {
    local rc=0 fam
    for fam in 4 6; do
        if ! _halow_fw_remove_chains "$fam" filter "$(_halow_fw_name "$fam" IN)" "$(_halow_fw_name "$fam" OUT)" "$(_halow_fw_name "$fam" FIN)" "$(_halow_fw_name "$fam" PAR)"; then
            rc=1
            continue
        fi
        # Every add-on rule and jump is gone: an INPUT base chain this add-on created goes too.
        _halow_fw_release_input "$fam" || rc=1
    done
    if [ "$rc" -eq 0 ]; then
        halow_own_clear fw_filter
        return 0
    fi
    halow_log_error "firewall: removal of the filter chains is unconfirmed"
    return 1
}

# halow_fw_present — recognises the add-on's chains and jumps from the host (not from
# markers). Prints one line per finding ("ipv4 filter chain HALOW-IN",
# "ipv4 filter jump INPUT -> HALOW-IN", "ipv6 filter unverifiable", ...). 0 if anything
# exists or a table could not be read (absence unconfirmed); 1 if confirmed absent.
halow_fw_present() {
    local found=1 fam table listing c line t
    local -a names
    for fam in 4 6; do
        for table in filter nat; do
            if [ "$table" = "nat" ] && [ "$fam" = "6" ]; then continue; fi
            if [ "$table" = "nat" ]; then
                names=("$(_halow_fw_name "$fam" NAT)")
            else
                names=("$(_halow_fw_name "$fam" IN)" "$(_halow_fw_name "$fam" OUT)" "$(_halow_fw_name "$fam" FIN)" "$(_halow_fw_name "$fam" PAR)")
            fi
            if listing="$(_halow_fw_list "$fam" "$table")"; then :; else
                printf 'ipv%s %s unverifiable\n' "$fam" "$table"
                found=0
                continue
            fi
            for c in "${names[@]}"; do
                if _halow_fw_has_chain "$listing" "$c"; then
                    printf 'ipv%s %s chain %s\n' "$fam" "$table" "$c"
                    found=0
                fi
            done
            while IFS= read -r line; do
                [ -z "$line" ] && continue
                t="$(_halow_fw_target "${line#*|*|}")"
                printf 'ipv%s %s jump %s -> %s\n' "$fam" "$table" "${line%%|*}" "$t"
                found=0
            done <<< "$(_halow_fw_jumps "$listing" "${names[@]}")"
        done
    done
    return "$found"
}

# halow_fw_ipv6_governed [<bridge>] — read-only check of the second IPv6 layer: 0 when
# HALOW-IN6, HALOW-FWD-OUT6 and HALOW-FWD-IN6 (and HALOW-PARENT6 when a parent interface
# was recorded) exist, each ending in its terminal drop, and their jumps sit at the
# positions the install puts them (INPUT 1 and 2; forwarding hook 1, 2 and 3). 1
# otherwise, including when the table cannot be read.
halow_fw_ipv6_governed() {
    local bridge="${1:-}" parent listing hook c last r
    if [ -z "$bridge" ]; then
        bridge="$(_halow_fw_marker_field bridge)"
        [ -n "$bridge" ] || bridge="$HALOW_BRIDGE_NAME"
    fi
    parent="$(_halow_fw_marker_field parent)"
    if listing="$(_halow_fw_list 6 filter)"; then :; else return 1; fi
    local in6 out6 fin6 par6
    in6="$(_halow_fw_name 6 IN)"; out6="$(_halow_fw_name 6 OUT)"; fin6="$(_halow_fw_name 6 FIN)"; par6="$(_halow_fw_name 6 PAR)"
    local -a chains=("$in6" "$out6" "$fin6")
    if [ -n "$parent" ]; then chains+=("$par6"); fi
    for c in "${chains[@]}"; do
        _halow_fw_has_chain "$listing" "$c" || return 1
        last=""
        while IFS= read -r r; do [ -n "$r" ] && last="$r"; done <<< "$(_halow_fw_rules_of "$listing" "$c")"
        [ "$last" = "-j DROP" ] || return 1
    done
    hook="$(_halow_fw_hook_chain "$listing")"
    local -a want=("INPUT|1|-i ${bridge} -j ${in6}" "${hook}|1|-i ${bridge} -j ${out6}" "${hook}|2|-o ${bridge} -j ${fin6}")
    if [ -n "$parent" ]; then want+=("INPUT|2|-i ${parent}+ -j ${par6}" "${hook}|3|-i ${parent}+ -j ${par6}"); fi
    local jumps
    jumps="$(_halow_fw_jumps "$listing" "${chains[@]}")"
    for r in "${want[@]}"; do
        case $'\n'"$jumps"$'\n' in *$'\n'"$r"$'\n'*) ;; *) return 1 ;; esac
    done
    return 0
}

# halow_fw_reassert [<bridge>] — re-asserts every jump position (insert first, then delete
# stale duplicates and jumps left in the other forwarding hook), including the catch-all
# for the parent interface recorded at install. The bridge defaults to the one recorded
# at install, else HALOW_BRIDGE_NAME. 0 when every installed chain is hooked correctly (or
# nothing is installed); 1 when a table cannot be read, a recorded chain is missing, or a
# jump cannot be restored: the caller must then treat the firewall as not in force.
halow_fw_reassert() {
    local bridge="${1:-}" parent rc=0 fam listing any nat
    if [ -z "$bridge" ]; then
        bridge="$(_halow_fw_marker_field bridge)"
        [ -n "$bridge" ] || bridge="$HALOW_BRIDGE_NAME"
    fi
    if ! halow_validate_iface_name "$bridge"; then return 1; fi
    parent="$(_halow_fw_marker_field parent)"
    if [ -n "$parent" ] && ! halow_validate_iface_name "$parent"; then
        halow_log_error "firewall: the recorded parent interface is malformed"
        return 1
    fi
    for fam in 4 6; do
        if listing="$(_halow_fw_list "$fam" filter)"; then :; else
            halow_log_error "firewall: cannot list the filter table (IPv$fam)"
            rc=1
            continue
        fi
        any=0
        _halow_fw_has_chain "$listing" "$(_halow_fw_name "$fam" IN)" && any=1
        _halow_fw_has_chain "$listing" "$(_halow_fw_name "$fam" OUT)" && any=1
        _halow_fw_has_chain "$listing" "$(_halow_fw_name "$fam" FIN)" && any=1
        _halow_fw_has_chain "$listing" "$(_halow_fw_name "$fam" PAR)" && any=1
        if [ "$any" -eq 1 ] || halow_own_check fw_filter; then
            _halow_fw_reassert_filter "$fam" "$bridge" "$parent" || rc=1
        fi
    done
    nat="$(_halow_fw_name 4 NAT)"
    if listing="$(_halow_fw_list 4 nat)"; then
        if _halow_fw_has_chain "$listing" "$nat"; then
            if ! { _halow_fw_place 4 nat POSTROUTING 1 "-j ${nat}" && _halow_fw_sweep 4 nat "POSTROUTING|1|-j ${nat}" "$nat"; }; then
                rc=1
            fi
        elif halow_own_check fw_nat; then
            halow_log_error "firewall: the NAT chain is recorded but missing from the host"
            rc=1
        fi
    else
        rc=1
    fi
    return "$rc"
}
