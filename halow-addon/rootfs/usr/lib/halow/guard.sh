#!/usr/bin/env bash
# halow: kernel compatibility guard. Runs before any host change and refuses to continue unless
# the host runs exactly the kernel and the exact in-kernel modules the bundled driver modules
# were built for. It only reads: the kernel release and build string, /proc/version, the
# embedded kernel configuration (/proc/config.gz), the host's module tree (mounted read-only
# into the container), /sys/module and the bundled driver modules. It never loads, unloads or
# writes anything.
#
# Why exact module identity: the bundled morse.ko and dot11ah.ko call into the in-kernel
# cfg80211, mac80211 and libarc4. The supported kernel is built without symbol versioning, so a
# different build of those modules with the same release string would be accepted by the
# kernel, and a structure-layout difference then crashes the host instead of failing the load.
# The guard therefore requires, for each of the three, the exact official module file: the path
# the module loader would use, a single copy in the tree, a regular file whose SHA-256 equals
# the recorded value, and the supported vermagic; a loaded copy must be untainted and, where its
# build-id is readable, carry the recorded build-id.
#
# What it can and cannot establish: it identifies the exact official module files of the
# supported release and the running kernel's banner and configuration. It cannot defend against
# a hostile root user on the host or a kernel deliberately forged to mimic these strings. Only
# the supported release is accepted; any other release is refused until its values are added
# to the manifest.
#
# Data: guard_manifest.psv (see its header for the format and where the values come from).
#
# Test overrides: only when HALOW_GUARD_TEST_MODE=1 are HALOW_GUARD_MANIFEST,
# HALOW_UNAME_RELEASE, HALOW_UNAME_VERSION, HALOW_PROC_VERSION, HALOW_PROC_CONFIG_GZ,
# HALOW_MODULES_BASE (the module tree is <base>/lib/modules) and HALOW_SYS_MODULE_DIR honoured;
# otherwise they are ignored and the production paths and `uname` are used. The bundled modules
# are read from HALOW_ARTIFACTS_DIR (shared with the rest of the add-on). External commands
# (uname, modinfo, sha256sum, zcat, od, find) are called by name so tests can put fakes first on
# PATH.
#
# Not checked: the dependency chain modprobe would load (modprobe --show-depends). The module
# file is resolved through the same module index modprobe uses (modinfo -F filename), and the
# single-copy check covers the rest of the tree; the chain itself is reported as unverified.
#
# Return codes of halow_guard_check: 0 supported; 1 unsupported; 2 undeterminable or malformed
# data. Both 1 and 2 are refusals. HALOW_GUARD_REASON holds one line naming the check that
# failed (no secrets: only release strings, module names, paths and hashes).

# _halow_guard_ovr <variable> <production value>: the test override only in test mode.
_halow_guard_ovr() {
    if [ "${HALOW_GUARD_TEST_MODE:-0}" = "1" ] && [ -n "${!1:-}" ]; then
        printf '%s' "${!1}"
    else
        printf '%s' "$2"
    fi
}
_halow_guard_manifest_path() { _halow_guard_ovr HALOW_GUARD_MANIFEST /usr/share/halow/guard_manifest.psv; }
_halow_guard_modules_base() { _halow_guard_ovr HALOW_MODULES_BASE /; }
_halow_guard_modules_root() { local b; b="$(_halow_guard_modules_base)"; printf '%s/lib/modules' "${b%/}"; }
_halow_guard_sys_module_dir() { _halow_guard_ovr HALOW_SYS_MODULE_DIR /sys/module; }
_halow_guard_artifacts_dir() { printf '%s' "${HALOW_ARTIFACTS_DIR:-/opt/halow/artifacts}"; }
_halow_guard_proc_version() { _halow_guard_ovr HALOW_PROC_VERSION /proc/version; }
_halow_guard_proc_config() { _halow_guard_ovr HALOW_PROC_CONFIG_GZ /proc/config.gz; }

# The host modules whose identity must match. Fixed by design, not configurable.
_halow_guard_host_modules() { printf '%s\n' cfg80211 mac80211 libarc4; }

_halow_guard_log_error() {
    if declare -F halow_log_error >/dev/null 2>&1; then
        halow_log_error "$*"
    else
        printf '[halow] ERROR: %s\n' "$*" >&2
    fi
}

# _halow_guard_why <reason>: records and logs the refusal reason (always returns 0).
_halow_guard_why() {
    HALOW_GUARD_REASON="$1"
    _halow_guard_log_error "guard: $1"
}

# _halow_guard_clean <string>: first line only, carriage returns removed, outer blanks trimmed.
_halow_guard_clean() {
    local v="$1"
    v="${v%%$'\n'*}"
    v="${v//$'\r'/}"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    printf '%s' "$v"
}

# _halow_guard_squash <path>: repeated slashes collapsed (path comparison only).
_halow_guard_squash() {
    local p="$1"
    while [[ "$p" == *//* ]]; do p="${p//\/\//\/}"; done
    printf '%s' "$p"
}

_halow_guard_release() {
    local r
    if [ "${HALOW_GUARD_TEST_MODE:-0}" = "1" ] && [ -n "${HALOW_UNAME_RELEASE:-}" ]; then
        r="$HALOW_UNAME_RELEASE"
    elif r="$(uname -r 2>/dev/null)"; then
        :
    else
        return 1
    fi
    r="$(_halow_guard_clean "$r")"
    [ -n "$r" ] || return 1
    printf '%s' "$r"
}

_halow_guard_build() {
    local v
    if [ "${HALOW_GUARD_TEST_MODE:-0}" = "1" ] && [ -n "${HALOW_UNAME_VERSION:-}" ]; then
        v="$HALOW_UNAME_VERSION"
    elif v="$(uname -v 2>/dev/null)"; then
        :
    else
        return 1
    fi
    v="$(_halow_guard_clean "$v")"
    [ -n "$v" ] || return 1
    printf '%s' "$v"
}

# _halow_guard_banner: prints the running kernel's /proc/version line; 1 if unreadable or empty.
_halow_guard_banner() {
    local f v
    f="$(_halow_guard_proc_version)"
    [ -f "$f" ] && [ -r "$f" ] || return 1
    if v="$(<"$f")"; then :; else return 1; fi
    v="$(_halow_guard_clean "$v")"
    [ -n "$v" ] || return 1
    printf '%s' "$v"
}

# _halow_guard_config_hash: prints the SHA-256 of the decompressed embedded kernel configuration.
_halow_guard_config_hash() {
    local f out h
    local -
    set -o pipefail
    f="$(_halow_guard_proc_config)"
    [ -f "$f" ] && [ -r "$f" ] || return 1
    if out="$(zcat "$f" | sha256sum)"; then :; else return 1; fi
    h="${out%% *}"
    [[ "$h" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s' "$h"
}

_halow_guard_is_hash() { [[ "$1" =~ ^[0-9A-F]{16,40}$ ]]; }

# _halow_guard_valid_relpath <module> <path>: a relative path without "..", ending in the
# module's own file name with an optional compression suffix.
_halow_guard_valid_relpath() {
    local mod="$1" p="$2" base
    [[ "$p" =~ ^[A-Za-z0-9._/-]+$ ]] || return 1
    case "$p" in /*|*//*|../*|*/../*|*/..|..) return 1 ;; esac
    base="${p##*/}"
    case "$base" in "$mod.ko"|"$mod.ko.xz"|"$mod.ko.gz"|"$mod.ko.zst") return 0 ;; esac
    return 1
}

# _halow_guard_load_manifest <file>
# Fills _HALOW_GUARD_VERMAGIC[rel], _HALOW_GUARD_BUILD[rel], _HALOW_GUARD_BANNER[rel],
# _HALOW_GUARD_CONFIG[rel], _HALOW_GUARD_HPATH/_HALOW_GUARD_HSHA/_HALOW_GUARD_HBID[rel|module],
# _HALOW_GUARD_ART[rel|file], _HALOW_GUARD_ART_LIST[rel] and _HALOW_GUARD_RELEASES. Returns 1
# with HALOW_GUARD_REASON set on any malformed or incomplete content: a manifest that cannot be
# trusted is never partially used.
_halow_guard_load_manifest() {
    local file="$1" line pipes kind rel f3 f4 f5 f6 n=0 m k want
    declare -gA _HALOW_GUARD_VERMAGIC=() _HALOW_GUARD_BUILD=() _HALOW_GUARD_BANNER=() _HALOW_GUARD_CONFIG=() \
        _HALOW_GUARD_HPATH=() _HALOW_GUARD_HSHA=() _HALOW_GUARD_HBID=() _HALOW_GUARD_ART=() _HALOW_GUARD_ART_LIST=()
    _HALOW_GUARD_RELEASES=""
    if [ ! -f "$file" ] || [ ! -r "$file" ]; then
        HALOW_GUARD_REASON="compatibility manifest missing or unreadable: $file"
        return 1
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        line="${line//$'\r'/}"
        case "$line" in ''|'#'*) continue ;; esac
        kind="${line%%|*}"
        case "$kind" in
            release|kernel_build|artifact) want=3 ;;
            kernel_banner|kernel_config) want=2 ;;
            host_module) want=5 ;;
            *)
                HALOW_GUARD_REASON="compatibility manifest malformed at line $n: unknown record type '$kind'"
                return 1 ;;
        esac
        pipes="${line//[^|]/}"
        if [ "${#pipes}" -ne "$want" ]; then
            HALOW_GUARD_REASON="compatibility manifest malformed at line $n: expected $((want + 1)) fields for $kind"
            return 1
        fi
        f3=""; f4=""; f5=""; f6=""
        IFS='|' read -r kind rel f3 f4 f5 f6 <<< "$line"
        if [ -z "$rel" ] || [ -z "$f3" ] || { [ "$want" -ge 3 ] && [ -z "$f4" ]; } || { [ "$want" -ge 5 ] && { [ -z "$f5" ] || [ -z "$f6" ]; }; }; then
            HALOW_GUARD_REASON="compatibility manifest malformed at line $n: empty field"
            return 1
        fi
        if [[ ! "$rel" =~ ^[A-Za-z0-9._+-]+$ ]]; then
            HALOW_GUARD_REASON="compatibility manifest malformed at line $n: invalid release"
            return 1
        fi
        case "$kind" in
            release)
                if [ "$f3" != "vermagic" ] || [ -n "${_HALOW_GUARD_VERMAGIC[$rel]+x}" ]; then
                    HALOW_GUARD_REASON="compatibility manifest malformed at line $n: bad or duplicate release row"
                    return 1
                fi
                _HALOW_GUARD_VERMAGIC[$rel]="$f4"
                _HALOW_GUARD_RELEASES="${_HALOW_GUARD_RELEASES:+$_HALOW_GUARD_RELEASES }$rel"
                ;;
            kernel_build)
                if [ "$f3" != "uname_v" ] || [ -n "${_HALOW_GUARD_BUILD[$rel]+x}" ]; then
                    HALOW_GUARD_REASON="compatibility manifest malformed at line $n: bad or duplicate kernel build row"
                    return 1
                fi
                _HALOW_GUARD_BUILD[$rel]="$f4"
                ;;
            kernel_banner)
                if [ -n "${_HALOW_GUARD_BANNER[$rel]+x}" ]; then
                    HALOW_GUARD_REASON="compatibility manifest malformed at line $n: duplicate kernel banner row"
                    return 1
                fi
                _HALOW_GUARD_BANNER[$rel]="$f3"
                ;;
            kernel_config)
                if [[ ! "$f3" =~ ^[0-9a-f]{64}$ ]] || [ -n "${_HALOW_GUARD_CONFIG[$rel]+x}" ]; then
                    HALOW_GUARD_REASON="compatibility manifest malformed at line $n: bad or duplicate kernel config hash"
                    return 1
                fi
                _HALOW_GUARD_CONFIG[$rel]="$f3"
                ;;
            host_module)
                case "$f3" in cfg80211|mac80211|libarc4) ;; *)
                    HALOW_GUARD_REASON="compatibility manifest malformed at line $n: unknown host module '$f3'"
                    return 1 ;;
                esac
                if [ -n "${_HALOW_GUARD_HPATH[$rel|$f3]+x}" ]; then
                    HALOW_GUARD_REASON="compatibility manifest malformed at line $n: duplicate host module $f3"
                    return 1
                fi
                if ! _halow_guard_valid_relpath "$f3" "$f4"; then
                    HALOW_GUARD_REASON="compatibility manifest malformed at line $n: bad path for $f3"
                    return 1
                fi
                if [[ ! "$f5" =~ ^[0-9a-f]{64}$ ]]; then
                    HALOW_GUARD_REASON="compatibility manifest malformed at line $n: bad SHA-256 for $f3"
                    return 1
                fi
                if [[ ! "$f6" =~ ^[0-9a-f]{40}$ ]]; then
                    HALOW_GUARD_REASON="compatibility manifest malformed at line $n: bad build-id for $f3"
                    return 1
                fi
                _HALOW_GUARD_HPATH[$rel|$f3]="$f4"
                _HALOW_GUARD_HSHA[$rel|$f3]="$f5"
                _HALOW_GUARD_HBID[$rel|$f3]="$f6"
                ;;
            artifact)
                if [[ ! "$f3" =~ ^[A-Za-z0-9._-]+\.ko$ ]] || { [ "$f4" != "none" ] && ! _halow_guard_is_hash "$f4"; } \
                   || [ -n "${_HALOW_GUARD_ART[$rel|$f3]+x}" ]; then
                    HALOW_GUARD_REASON="compatibility manifest malformed at line $n: bad or duplicate artifact row"
                    return 1
                fi
                _HALOW_GUARD_ART[$rel|$f3]="$f4"
                _HALOW_GUARD_ART_LIST[$rel]="${_HALOW_GUARD_ART_LIST[$rel]:-}${_HALOW_GUARD_ART_LIST[$rel]:+ }$f3"
                ;;
        esac
    done < "$file"
    if [ -z "$_HALOW_GUARD_RELEASES" ]; then
        HALOW_GUARD_REASON="compatibility manifest lists no supported kernel release"
        return 1
    fi
    for rel in $_HALOW_GUARD_RELEASES; do
        if [ -z "${_HALOW_GUARD_BUILD[$rel]+x}" ] || [ -z "${_HALOW_GUARD_BANNER[$rel]+x}" ] || [ -z "${_HALOW_GUARD_CONFIG[$rel]+x}" ]; then
            HALOW_GUARD_REASON="compatibility manifest incomplete: kernel build, banner or configuration row missing for $rel"
            return 1
        fi
        while IFS= read -r m; do
            if [ -z "${_HALOW_GUARD_HPATH[$rel|$m]+x}" ]; then
                HALOW_GUARD_REASON="compatibility manifest incomplete: no host_module row for $m in $rel"
                return 1
            fi
        done < <(_halow_guard_host_modules)
        for m in morse.ko dot11ah.ko; do
            if [ -z "${_HALOW_GUARD_ART[$rel|$m]+x}" ]; then
                HALOW_GUARD_REASON="compatibility manifest incomplete: no $m row for $rel"
                return 1
            fi
        done
    done
    # Rows for a release that has no release row.
    for k in "${!_HALOW_GUARD_BUILD[@]}" "${!_HALOW_GUARD_BANNER[@]}" "${!_HALOW_GUARD_CONFIG[@]}" \
             "${!_HALOW_GUARD_HPATH[@]}" "${!_HALOW_GUARD_ART[@]}"; do
        rel="${k%%|*}"
        if [ -z "${_HALOW_GUARD_VERMAGIC[$rel]+x}" ]; then
            HALOW_GUARD_REASON="compatibility manifest malformed: rows for $rel without a release row"
            return 1
        fi
    done
    return 0
}

# _halow_guard_modinfo <field> <file>: prints the cleaned field; 1 if modinfo failed.
_halow_guard_modinfo() {
    local out
    if out="$(modinfo -F "$1" "$2" 2>/dev/null)"; then
        _halow_guard_clean "$out"
    else
        return 1
    fi
}

# _halow_guard_resolve <release> <module>: prints the file the module loader would use.
_halow_guard_resolve() {
    local out
    if out="$(modinfo -b "$(_halow_guard_modules_base)" -k "$1" -F filename "$2" 2>/dev/null)"; then
        out="$(_halow_guard_clean "$out")"
        [ -n "$out" ] || return 1
        printf '%s' "$out"
    else
        return 1
    fi
}

# _halow_guard_copies <release> <module>: prints how many files named <module>.ko* exist in the
# release's module tree; 1 if the tree cannot be searched.
_halow_guard_copies() {
    local tree out line count=0
    tree="$(_halow_guard_modules_root)/$1"
    [ -d "$tree" ] || return 1
    if out="$(find -L "$tree" -name "$2.ko*" \( -type f -o -type l \) 2>/dev/null)"; then :; else return 1; fi
    while IFS= read -r line; do
        [ -n "$line" ] && count=$((count + 1))
    done <<< "$out"
    printf '%s' "$count"
}

_halow_guard_sha256() {
    local out h
    if out="$(sha256sum "$1" 2>/dev/null)"; then :; else return 1; fi
    h="${out%% *}"
    [[ "$h" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s' "$h"
}

# _halow_guard_note_build_id <note file>: prints the 40-hex-digit GNU build-id of a raw ELF note
# (namesz, descsz, type, "GNU\0", descriptor); 1 if unreadable or not such a note.
_halow_guard_note_build_id() {
    local out i hex=""
    local -a b
    if out="$(od -An -v -t x1 "$1" 2>/dev/null)"; then :; else return 1; fi
    read -r -d '' -a b <<< "$out" || true
    [ "${#b[@]}" -ge 36 ] || return 1
    [ "${b[0]}${b[1]}${b[2]}${b[3]}" = "04000000" ] || return 1
    [ "${b[4]}${b[5]}${b[6]}${b[7]}" = "14000000" ] || return 1
    [ "${b[8]}${b[9]}${b[10]}${b[11]}" = "03000000" ] || return 1
    [ "${b[12]}${b[13]}${b[14]}${b[15]}" = "474e5500" ] || return 1
    for ((i = 16; i < 36; i++)); do hex="${hex}${b[$i]}"; done
    printf '%s' "$hex"
}

# _halow_guard_check_host_module <release> <module> <vermagic>: 0 / 1 / 2 as halow_guard_check.
_halow_guard_check_host_module() {
    local rel="$1" mod="$2" vermagic="$3" relpath want path resolved copies actual
    relpath="${_HALOW_GUARD_HPATH[$rel|$mod]}"
    want="${_HALOW_GUARD_HSHA[$rel|$mod]}"
    path="$(_halow_guard_modules_root)/$rel/$relpath"
    # (a) the file the module loader would use is the recorded one
    if ! resolved="$(_halow_guard_resolve "$rel" "$mod")"; then
        _halow_guard_why "host module $mod could not be resolved in the module tree for $rel"
        return 2
    fi
    if [ "$(_halow_guard_squash "$resolved")" != "$(_halow_guard_squash "$path")" ]; then
        _halow_guard_why "host module $mod resolves to '$resolved', not the supported '$relpath'"
        return 1
    fi
    # (b) exactly one copy anywhere in the release's tree
    if ! copies="$(_halow_guard_copies "$rel" "$mod")"; then
        _halow_guard_why "module tree for $rel could not be searched for $mod"
        return 2
    fi
    if [ "$copies" -gt 1 ]; then
        _halow_guard_why "host module $mod exists $copies times in the module tree for $rel"
        return 1
    fi
    # (c) a regular, readable file (a symbolic link is not accepted)
    if [ -L "$path" ]; then
        _halow_guard_why "host module $mod at '$relpath' is a symbolic link, not the supported file"
        return 1
    fi
    if [ ! -e "$path" ]; then
        _halow_guard_why "host module $mod not found at '$relpath'"
        return 2
    fi
    if [ ! -f "$path" ]; then
        _halow_guard_why "host module $mod at '$relpath' is not a regular file"
        return 1
    fi
    if [ ! -r "$path" ]; then
        _halow_guard_why "host module $mod could not be read"
        return 2
    fi
    # (d) the exact official file
    if ! actual="$(_halow_guard_sha256 "$path")"; then
        _halow_guard_why "host module $mod could not be hashed"
        return 2
    fi
    if [ "$actual" != "$want" ]; then
        _halow_guard_why "host module $mod SHA-256 $actual does not match the supported file"
        return 1
    fi
    # (e) its vermagic (defence in depth); modinfo cannot read a zstd-compressed module here
    case "$relpath" in
        *.zst)
            _halow_guard_why "metadata of host module $mod (zstd-compressed) cannot be read"
            return 2 ;;
    esac
    if ! actual="$(_halow_guard_modinfo vermagic "$path")" || [ -z "$actual" ]; then
        _halow_guard_why "vermagic of host module $mod could not be read"
        return 2
    fi
    if [ "$actual" != "$vermagic" ]; then
        _halow_guard_why "host module $mod vermagic '$actual' does not match '$vermagic'"
        return 1
    fi
    return 0
}

# _halow_guard_sys_module_readable: 0 if the loaded-module directory exists, can be listed and
# has at least one entry (a real one always lists many modules).
_halow_guard_sys_module_readable() {
    local d e
    d="$(_halow_guard_sys_module_dir)"
    [ -d "$d" ] && [ -r "$d" ] && [ -x "$d" ] || return 1
    for e in "$d"/*; do
        if [ -e "$e" ]; then return 0; fi
    done
    return 1
}

# _halow_guard_check_loaded <release> <module>: 0 / 1 / 2 for a module already loaded (the
# caller has established that the loaded-module directory is readable).
_halow_guard_check_loaded() {
    local rel="$1" mod="$2" d taint bid
    d="$(_halow_guard_sys_module_dir)/$mod"
    [ -d "$d" ] || return 0
    if [ ! -f "$d/taint" ] || [ ! -r "$d/taint" ] || ! taint="$(<"$d/taint")"; then
        _halow_guard_why "taint of loaded module $mod could not be read"
        return 2
    fi
    taint="${taint//[[:space:]]/}"
    if [ -n "$taint" ]; then
        _halow_guard_why "loaded module $mod is tainted ($taint): not the official signed module"
        return 1
    fi
    if [ -r "$d/notes/.note.gnu.build-id" ]; then
        if ! bid="$(_halow_guard_note_build_id "$d/notes/.note.gnu.build-id")"; then
            _halow_guard_why "build-id note of loaded module $mod could not be parsed"
            return 2
        fi
        if [ "$bid" != "${_HALOW_GUARD_HBID[$rel|$mod]}" ]; then
            _halow_guard_why "loaded module $mod build-id $bid does not match the supported module"
            return 1
        fi
    fi
    return 0
}

# halow_guard_check: see the header. Read-only.
halow_guard_check() {
    local manifest rel vermagic name expected path actual mod rc
    HALOW_GUARD_REASON=""
    manifest="$(_halow_guard_manifest_path)"
    if ! _halow_guard_load_manifest "$manifest"; then
        _halow_guard_log_error "guard: $HALOW_GUARD_REASON"
        return 2
    fi

    if ! rel="$(_halow_guard_release)"; then
        _halow_guard_why "host kernel release could not be read"
        return 2
    fi
    if [ -z "${_HALOW_GUARD_VERMAGIC[$rel]+x}" ]; then
        _halow_guard_why "host kernel release $rel is not supported by this build (supported: $_HALOW_GUARD_RELEASES)"
        return 1
    fi
    vermagic="${_HALOW_GUARD_VERMAGIC[$rel]}"

    if ! actual="$(_halow_guard_build)"; then
        _halow_guard_why "host kernel build string could not be read"
        return 2
    fi
    if [ "$actual" != "${_HALOW_GUARD_BUILD[$rel]}" ]; then
        _halow_guard_why "host kernel $rel build string '$actual' does not match the supported build"
        return 1
    fi

    if ! actual="$(_halow_guard_banner)"; then
        _halow_guard_why "kernel version banner could not be read"
        return 2
    fi
    if [ "$actual" != "${_HALOW_GUARD_BANNER[$rel]}" ]; then
        _halow_guard_why "kernel version banner does not match the supported build"
        return 1
    fi

    if ! actual="$(_halow_guard_config_hash)"; then
        _halow_guard_why "embedded kernel configuration could not be read"
        return 2
    fi
    if [ "$actual" != "${_HALOW_GUARD_CONFIG[$rel]}" ]; then
        _halow_guard_why "embedded kernel configuration SHA-256 $actual does not match the supported build"
        return 1
    fi

    # The bundled driver modules must have been built for exactly this kernel.
    for name in ${_HALOW_GUARD_ART_LIST[$rel]}; do
        path="$(_halow_guard_artifacts_dir)/$name"
        if [ ! -f "$path" ]; then
            _halow_guard_why "bundled driver module $name is missing"
            return 2
        fi
        if ! actual="$(_halow_guard_modinfo vermagic "$path")"; then
            _halow_guard_why "vermagic of bundled driver module $name could not be read"
            return 2
        fi
        if [ "$actual" != "$vermagic" ]; then
            _halow_guard_why "bundled driver module $name vermagic '$actual' does not match '$vermagic'"
            return 1
        fi
        expected="${_HALOW_GUARD_ART[$rel|$name]}"
        if [ "$expected" != "none" ]; then
            if ! actual="$(_halow_guard_modinfo srcversion "$path")"; then
                _halow_guard_why "source hash of bundled driver module $name could not be read"
                return 2
            fi
            if [ "$actual" != "$expected" ]; then
                _halow_guard_why "bundled driver module $name source hash '${actual:-none}' does not match '$expected'"
                return 1
            fi
        fi
    done

    # The host's cfg80211, mac80211 and libarc4 must be exactly the official files.
    while IFS= read -r mod; do
        if _halow_guard_check_host_module "$rel" "$mod" "$vermagic"; then rc=0; else rc=$?; fi
        if [ "$rc" -ne 0 ]; then return "$rc"; fi
    done < <(_halow_guard_host_modules)

    # Any of them already loaded must be the official module too. "Not loaded" is only
    # believed when the module directory itself is readable and lists other modules.
    if ! _halow_guard_sys_module_readable; then
        _halow_guard_why "loaded-module directory $(_halow_guard_sys_module_dir) is missing, unreadable or empty"
        return 2
    fi
    while IFS= read -r mod; do
        if _halow_guard_check_loaded "$rel" "$mod"; then rc=0; else rc=$?; fi
        if [ "$rc" -ne 0 ]; then return "$rc"; fi
    done < <(_halow_guard_host_modules)

    return 0
}

_halow_guard_kv() {
    local v="$2"
    v="${v//[$'\n\r\t']/ }"
    printf '%s=%s\n' "$1" "$v"
}

# halow_guard_report: key=value lines for diagnostics. Read-only; always returns 0.
halow_guard_report() {
    local manifest state="ok" rel="" known=0 name key path v mod rc reason d bid
    manifest="$(_halow_guard_manifest_path)"
    if halow_guard_check >/dev/null 2>&1; then rc=0; else rc=$?; fi
    reason="${HALOW_GUARD_REASON:-}"
    if ! _halow_guard_load_manifest "$manifest" 2>/dev/null; then state="invalid"; fi
    HALOW_GUARD_REASON="$reason"
    if ! rel="$(_halow_guard_release)"; then rel=""; fi
    if [ "$state" = "ok" ] && [ -n "$rel" ] && [ -n "${_HALOW_GUARD_VERMAGIC[$rel]+x}" ]; then known=1; fi
    _halow_guard_kv guard_result "$rc"
    _halow_guard_kv guard_reason "$reason"
    _halow_guard_kv guard_manifest "$manifest"
    _halow_guard_kv guard_manifest_state "$state"
    _halow_guard_kv kernel_release "${rel:-unknown}"
    if [ "${HALOW_GUARD_TEST_MODE:-0}" = "1" ]; then v="yes"; else v="no"; fi
    _halow_guard_kv guard_test_overrides "$v"
    _halow_guard_kv host_load_chain "unverified"
    if _halow_guard_sys_module_readable; then v="readable"; else v="unreadable"; fi
    _halow_guard_kv loaded_module_dir "$v"
    if [ "$state" = "ok" ]; then v="$_HALOW_GUARD_RELEASES"; else v=""; fi
    _halow_guard_kv supported_releases "$v"
    if v="$(_halow_guard_build)"; then :; else v="unreadable"; fi
    _halow_guard_kv kernel_build "$v"
    if [ "$known" -eq 1 ]; then
        _halow_guard_kv expected_kernel_build "${_HALOW_GUARD_BUILD[$rel]}"
        if v="$(_halow_guard_banner)"; then
            if [ "$v" = "${_HALOW_GUARD_BANNER[$rel]}" ]; then v="yes"; else v="no"; fi
        else
            v="unreadable"
        fi
        _halow_guard_kv kernel_banner_match "$v"
        if v="$(_halow_guard_config_hash)"; then
            _halow_guard_kv kernel_config_sha256 "$v"
            if [ "$v" = "${_HALOW_GUARD_CONFIG[$rel]}" ]; then v="yes"; else v="no"; fi
        else
            _halow_guard_kv kernel_config_sha256 "unreadable"
            v="unreadable"
        fi
        _halow_guard_kv kernel_config_match "$v"
        _halow_guard_kv expected_vermagic "${_HALOW_GUARD_VERMAGIC[$rel]}"
    else
        _halow_guard_kv expected_kernel_build ""
        _halow_guard_kv kernel_banner_match "unknown"
        _halow_guard_kv kernel_config_match "unknown"
        _halow_guard_kv expected_vermagic ""
    fi
    for name in morse.ko dot11ah.ko; do
        key="${name//./_}"
        path="$(_halow_guard_artifacts_dir)/$name"
        if [ -f "$path" ] && v="$(_halow_guard_modinfo vermagic "$path")"; then :; else v="unreadable"; fi
        _halow_guard_kv "artifact_${key}_vermagic" "$v"
        if [ -f "$path" ] && v="$(_halow_guard_modinfo srcversion "$path")"; then v="${v:-none}"; else v="unreadable"; fi
        _halow_guard_kv "artifact_${key}_srcversion" "$v"
    done
    while IFS= read -r mod; do
        if [ -n "$rel" ] && v="$(_halow_guard_resolve "$rel" "$mod")"; then :; else v="unresolved"; fi
        _halow_guard_kv "host_${mod}_path" "$v"
        if [ -n "$rel" ] && v="$(_halow_guard_copies "$rel" "$mod")"; then :; else v="unknown"; fi
        _halow_guard_kv "host_${mod}_copies" "$v"
        if [ "$known" -eq 1 ]; then
            _halow_guard_kv "expected_${mod}_path" "${_HALOW_GUARD_HPATH[$rel|$mod]}"
            path="$(_halow_guard_modules_root)/$rel/${_HALOW_GUARD_HPATH[$rel|$mod]}"
            if [ -f "$path" ] && [ ! -L "$path" ] && v="$(_halow_guard_sha256 "$path")"; then :; else v="unreadable"; fi
            _halow_guard_kv "host_${mod}_sha256" "$v"
            _halow_guard_kv "expected_${mod}_sha256" "${_HALOW_GUARD_HSHA[$rel|$mod]}"
        else
            _halow_guard_kv "expected_${mod}_path" ""
            _halow_guard_kv "host_${mod}_sha256" "unknown"
            _halow_guard_kv "expected_${mod}_sha256" ""
        fi
        d="$(_halow_guard_sys_module_dir)/$mod"
        if [ -d "$d" ]; then
            _halow_guard_kv "loaded_${mod}" "yes"
            if [ -r "$d/taint" ] && v="$(<"$d/taint")"; then v="${v//[[:space:]]/}"; v="${v:-none}"; else v="unreadable"; fi
            _halow_guard_kv "loaded_${mod}_taint" "$v"
            if [ ! -r "$d/notes/.note.gnu.build-id" ]; then
                v="unreadable"
            elif ! bid="$(_halow_guard_note_build_id "$d/notes/.note.gnu.build-id")"; then
                v="malformed"
            elif [ "$known" -eq 1 ] && [ "$bid" = "${_HALOW_GUARD_HBID[$rel|$mod]}" ]; then
                v="match"
            else
                v="mismatch"
            fi
            _halow_guard_kv "loaded_${mod}_build_id" "$v"
        else
            _halow_guard_kv "loaded_${mod}" "no"
            _halow_guard_kv "loaded_${mod}_taint" ""
            _halow_guard_kv "loaded_${mod}_build_id" ""
        fi
    done < <(_halow_guard_host_modules)
    return 0
}
