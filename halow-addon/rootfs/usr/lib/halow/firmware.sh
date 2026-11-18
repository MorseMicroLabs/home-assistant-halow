#!/usr/bin/env bash
# halow: safe firmware placement inside this add-on's own documented, always-mounted
# /data persistent volume (see common.sh's own header for the full mechanism that makes
# this host-visible via the firmware-loader search path).
#
# Design properties:
#   - checksum-pinned: the source is verified before anything is written, and the
#     destination is verified again immediately after;
#   - truly atomic, no-clobber publication: the new content is written to a temp file
#     in the SAME directory as the destination, then linked into place with `ln`
#     (hard link) — `ln` either creates the destination atomically or fails with EEXIST
#     if something is already there, with no window in which a concurrent reader could
#     see a partially-written file, and no separate "check -e, then mv -f" step that
#     could race against something else creating the file in between;
#   - a pre-existing file at the destination is NEVER overwritten. If it is
#     byte-identical to what would have been written, it is treated as usable but NOT
#     package-owned (this package did not create it, so it must never later delete it —
#     it could be a foreign file that merely happens to match). If it differs, placement
#     fails closed;
#   - ownership is recorded only for content this package itself wrote, and ownership
#     marking itself is fail-closed: if the marker cannot be written, the just-written
#     file is removed again rather than left in an untracked state;
#   - any directory this package had to create to reach the destination is tracked
#     (ownership.sh) and only ever removed again if it is still empty;
#   - removal re-verifies the destination's checksum immediately before deleting, and
#     does not clear ownership if that re-check fails — content that changed since
#     placement is left in place for manual review, and a repeated cleanup attempt keeps
#     surfacing the problem rather than silently giving up after the first refusal.
#
# Return codes for halow_place_firmware: 0 = placed (or previously placed by this
# package and still correct) and owned; 2 = a pre-existing, byte-identical file is
# present but is NOT owned by this package (usable, but this package must never remove
# it); 1 = failed closed (checksum mismatch, foreign non-matching file, or a write/
# ownership-recording failure).
#
# This function only places the files inside /data; see module_load.sh's
# halow_set_firmware_search_path for the separate step that points the host kernel's
# firmware loader at them — this file's own placement logic is unchanged by, and unaware
# of, that mechanism.

# halow_place_firmware <src> <dest> <expected_sha256> <owner_key> <dir_owner_key>
halow_place_firmware() {
    local src="$1" dest="$2" expected="$3" owner_key="$4" dir_owner_key="$5"
    local destdir
    destdir="$(dirname -- "$dest")"

    if ! halow_verify_file_checksum "$src" "$expected"; then
        halow_log_error "firmware: source failed checksum verification, refusing to place $dest"
        return 1
    fi

    if ! halow_mkdir_tracked "$destdir" "$dir_owner_key"; then
        return 1
    fi

    if halow_own_check "$owner_key" && halow_verify_file_checksum "$dest" "$expected" >/dev/null 2>&1; then
        halow_log_info "firmware: $dest already placed and owned by this package, unchanged"
        return 0
    fi

    if [ -e "$dest" ]; then
        if halow_verify_file_checksum "$dest" "$expected" >/dev/null 2>&1; then
            # Byte-identical, but NOT recorded as ours (own_check above was false) —
            # this may be a foreign file that happens to match. Usable, but we must
            # never claim it, and must never later delete it.
            halow_log_warning "firmware: $dest already exists and matches expected content, but is not package-owned — using it as-is, will not remove it on cleanup"
            return 2
        fi
        halow_log_error "firmware: refusing to overwrite pre-existing, non-matching file at $dest (fail-closed; not package-owned, not touched)"
        return 1
    fi

    local tmp="${dest}.halow-tmp.$$"
    # cp --preserve=mode (GNU long option) is not supported by this image's own BusyBox
    # cp (confirmed live, 2026-10-20: BusyBox prints "unrecognized option: preserve=mode"
    # and refuses to run) -- `-p` is the POSIX/BusyBox-compatible equivalent, confirmed
    # by direct smoke test inside the real ARM64 image to preserve mode correctly.
    if ! cp -p -- "$src" "$tmp"; then
        halow_log_error "firmware: could not stage a copy at $tmp"
        rm -f -- "$tmp"
        return 1
    fi

    if ! ln -- "$tmp" "$dest" 2>/dev/null; then
        # Either a genuine write failure, or something created $dest between our
        # existence check above and this attempt (TOCTOU) — in the latter case `ln`
        # itself refuses rather than silently overwriting, which is exactly the
        # no-clobber property this design relies on.
        rm -f -- "$tmp"
        if [ -e "$dest" ]; then
            halow_log_error "firmware: $dest was created concurrently; refusing to overwrite (fail-closed)"
        else
            halow_log_error "firmware: could not publish $dest (ln failed)"
        fi
        return 1
    fi
    rm -f -- "$tmp"

    if ! halow_verify_file_checksum "$dest" "$expected"; then
        halow_log_error "firmware: post-write verification failed for $dest — removing the bad write"
        rm -f -- "$dest"
        return 1
    fi

    if ! halow_own_mark "$owner_key"; then
        halow_log_error "firmware: wrote $dest but could not record ownership — removing it again (fail closed, never leave an untracked write behind)"
        rm -f -- "$dest"
        return 1
    fi

    halow_log_info "firmware: placed and verified $dest"
}

# halow_remove_firmware <dest> <expected_sha256> <owner_key> <dir_owner_key>
halow_remove_firmware() {
    local dest="$1" expected="$2" owner_key="$3" dir_owner_key="$4"
    local destdir
    destdir="$(dirname -- "$dest")"

    local status=0
    if ! halow_own_check "$owner_key"; then
        halow_log_info "firmware: $dest not package-owned, leaving it in place"
    elif [ -e "$dest" ]; then
        if halow_verify_file_checksum "$dest" "$expected" >/dev/null 2>&1; then
            rm -f -- "$dest"
            halow_log_info "firmware: removed $dest"
            halow_own_clear "$owner_key"
        else
            # Deliberately do NOT clear ownership here: the content no longer matches
            # what we placed, so we refuse to delete it (fail closed) — but leaving the
            # ownership record in place means a repeated cleanup attempt keeps
            # surfacing this exact problem instead of silently going quiet after the
            # first refusal.
            halow_log_error "firmware: refusing to remove $dest — its content changed since placement (fail-closed, left in place for manual review)"
            status=1
        fi
    else
        halow_own_clear "$owner_key"
    fi

    # This function's own success/failure is the file-removal outcome above, determined
    # and fixed in $status before this call — never whatever halow_rmdir_tracked itself
    # happens to return (it legitimately returns success for "directory not empty, left
    # in place", which is not a failure of this function, but must also never silently
    # overwrite a real refusal-to-delete above by being the last command executed).
    halow_rmdir_tracked "$destdir" "$dir_owner_key"
    return "$status"
}
