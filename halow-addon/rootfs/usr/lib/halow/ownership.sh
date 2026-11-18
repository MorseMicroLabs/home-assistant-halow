#!/usr/bin/env bash
# halow: ownership tracking. Every host-side artefact this package creates (firmware
# files, the udev rule, directories it had to create to reach them, loaded modules,
# applied network state) is recorded here, in the package's own documented persistent
# storage (HALOW_STATE_DIR), so cleanup never removes or unloads something this
# package did not itself create.

# halow_own_mark <key> [<content>]
# Fails closed: callers must check this call's own exit status. If the marker cannot be
# written, the artefact it would describe must be treated as NOT safely tracked — the
# caller should undo whatever it just did rather than proceed believing cleanup will
# later find it. <content>, if given, is stored verbatim and retrievable via
# halow_own_get — used by halow_mkdir_tracked to remember exactly which directories
# it created (plain presence is not enough when more than one path component may need
# creating).
halow_own_mark() {
    local key="$1" content="${2:-}" dir="${HALOW_STATE_DIR:?}/owns"
    mkdir -p -- "$dir" || { halow_log_error "ownership: could not create $dir"; return 1; }
    printf '%s' "$content" > "$dir/$key.tmp.$$" || { halow_log_error "ownership: could not write $dir/$key.tmp.$$"; rm -f -- "$dir/$key.tmp.$$"; return 1; }
    mv -f -- "$dir/$key.tmp.$$" "$dir/$key" || { halow_log_error "ownership: could not finalise $dir/$key"; rm -f -- "$dir/$key.tmp.$$"; return 1; }
}

# halow_own_check <key> — exit 0 if this package recorded ownership of <key>
halow_own_check() {
    local key="$1" dir="${HALOW_STATE_DIR:?}/owns"
    [ -e "$dir/$key" ]
}

# halow_own_get <key> — prints the marker's own stored content (empty if none/absent).
halow_own_get() {
    local key="$1" dir="${HALOW_STATE_DIR:?}/owns"
    cat "$dir/$key" 2>/dev/null || true
}

# halow_own_clear <key>
halow_own_clear() {
    local key="$1" dir="${HALOW_STATE_DIR:?}/owns"
    rm -f -- "$dir/$key"
}

# halow_own_list — for diagnostics/tests: print every currently-owned key, one per line.
# Uses plain `ls`, not GNU find's `-printf`, so this also works under HAOS's BusyBox.
halow_own_list() {
    local dir="${HALOW_STATE_DIR:?}/owns"
    [ -d "$dir" ] || return 0
    (cd "$dir" && ls -1 -- . 2>/dev/null) || true
}

# --- Directory ownership: tracks EACH individual path component this package actually
# had to create to reach a destination (not just the leaf, which could silently involve
# `mkdir -p` creating several untracked parent levels) — so cleanup removes exactly, and
# only, what this package created, in reverse (deepest-first) order, and nothing a
# pre-existing parent structure already provided. ---

# halow_rmdir_list <newline_separated_dirs>
# Internal helper: removes each listed directory in REVERSE order (deepest first,
# matching creation order reversed), stopping the removal of any single entry that is
# not empty (informational, not an error — something else may have since used it) but
# continuing to attempt the rest (a shallower directory may still be independently
# removable, or may become non-empty only because a deeper sibling could not be
# removed — each is judged on its own). Prints the directories that could NOT be
# removed (still present), one per line, on stdout, in the SAME shallow-to-deep order
# as the input list (not the reversed removal-attempt order) — so this output can be
# fed straight back in as the new "remaining" ownership content. Empty output means
# everything listed was successfully removed (or was already absent).
halow_rmdir_list() {
    local list="$1" d
    local reversed remaining_reversed=""
    reversed="$(printf '%s\n' "$list" | awk 'NF' | tac 2>/dev/null || printf '%s\n' "$list" | awk 'NF' | sed '1!G;h;$!d')"
    while IFS= read -r d; do
        [ -z "$d" ] && continue
        if [ ! -d "$d" ]; then
            continue
        fi
        if rmdir -- "$d" 2>/dev/null; then
            halow_log_info "ownership: removed package-created directory $d"
        else
            halow_log_info "ownership: $d not empty (or not removable); leaving it in place"
            remaining_reversed="${remaining_reversed}${d}
"
        fi
    done <<< "$reversed"
    # remaining_reversed was accumulated deepest-first; restore shallow-first order
    # (matching the original input/creation order) before returning it.
    if [ -n "$remaining_reversed" ]; then
        printf '%s\n' "$remaining_reversed" | awk 'NF' | tac 2>/dev/null || printf '%s\n' "$remaining_reversed" | awk 'NF' | sed '1!G;h;$!d'
    fi
    return 0
}

# halow_mkdir_tracked <dir> <owner_key>
# Creates every missing path component between the deepest already-existing ancestor
# and <dir> itself, ONE DIRECTORY AT A TIME (never a single `mkdir -p` that could
# create several untracked levels silently) — and records the exact ordered list of
# directories actually created, so halow_rmdir_tracked can later remove precisely
# those, and only those, never a pre-existing parent. If <dir> already exists, nothing
# is created and no ownership is claimed.
halow_mkdir_tracked() {
    local dir="$1" owner_key="$2"
    if [ -d "$dir" ]; then
        halow_log_info "ownership: directory $dir already existed; not claiming ownership of it"
        return 0
    fi

    # Walk up to the deepest existing ancestor.
    local existing="$dir"
    while [ "$existing" != "/" ] && [ -n "$existing" ] && [ ! -d "$existing" ]; do
        existing="$(dirname -- "$existing")"
    done
    if [ ! -d "$existing" ]; then
        halow_log_error "ownership: no existing ancestor found while creating $dir"
        return 1
    fi

    # Enumerate the missing path components between $existing and $dir, shallowest first.
    local rel="${dir#"$existing"}"
    rel="${rel#/}"
    local path="$existing" part created_list=""
    local saved_ifs="$IFS"
    IFS='/'
    for part in $rel; do
        IFS="$saved_ifs"
        [ -z "$part" ] && continue
        path="$path/$part"
        if [ ! -d "$path" ]; then
            if ! mkdir -- "$path"; then
                halow_log_error "ownership: could not create $path"
                [ -n "$created_list" ] && halow_rmdir_list "$created_list" >/dev/null
                return 1
            fi
            created_list="${created_list}${path}
"
        fi
        IFS='/'
    done
    IFS="$saved_ifs"

    if [ -z "$created_list" ]; then
        # Something else created the full path between our initial check and now
        # (a benign race) — we created nothing, so we own nothing.
        return 0
    fi

    if ! halow_own_mark "$owner_key" "$created_list"; then
        halow_log_error "ownership: created director(y/ies) for $dir but could not record ownership — removing again (fail closed, never leave an untracked write behind)"
        halow_rmdir_list "$created_list" >/dev/null
        return 1
    fi
}

# halow_rmdir_tracked <dir> <owner_key>
# Removes exactly the directories halow_mkdir_tracked recorded under <owner_key>, in
# reverse order, each only if still empty. Clears ownership only once every recorded
# directory has actually been removed; if any remain (non-empty, or otherwise
# unremovable), ownership is kept so a repeated cleanup attempt keeps trying — <dir>
# itself is accepted for API-compatibility/logging but the authoritative list is always
# the one actually recorded, never re-derived from <dir> alone (which cannot by itself
# say how many parent levels this package actually created).
halow_rmdir_tracked() {
    local dir="$1" owner_key="$2" list remaining
    if ! halow_own_check "$owner_key"; then
        return 0
    fi
    list="$(halow_own_get "$owner_key")"
    if [ -z "$list" ]; then
        # Recorded as owned but with no directory list — nothing to safely remove.
        halow_own_clear "$owner_key"
        return 0
    fi
    remaining="$(halow_rmdir_list "$list")"
    if [ -z "$remaining" ]; then
        halow_own_clear "$owner_key"
        return 0
    fi
    # Persist exactly the still-present directories, not the original full list — a
    # repeated cleanup attempt must re-check only what is actually still there, and
    # halow_own_get callers (including this function's own next invocation) must see
    # the current, accurate remainder, not stale, already-removed entries.
    if ! halow_own_mark "$owner_key" "$remaining"; then
        halow_log_error "ownership: could not update the remaining-directory record for $owner_key after a partial removal"
    fi
    halow_log_info "ownership: some package-created directories under $dir remain (not empty) — ownership kept"
    return 1
}
