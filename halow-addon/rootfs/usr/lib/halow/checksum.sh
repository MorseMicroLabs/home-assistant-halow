#!/usr/bin/env bash
# halow: checksum verification. Fail closed everywhere — never proceed on an unverified,
# missing, or mismatched file.

# halow_verify_file_checksum <file> <expected_sha256>
halow_verify_file_checksum() {
    local file="$1" expected="$2" actual
    if [ ! -f "$file" ]; then
        halow_log_error "checksum: missing file: $file"
        return 1
    fi
    actual="$(sha256sum -- "$file" | awk '{print $1}')"
    if [ "$actual" != "$expected" ]; then
        halow_log_error "checksum: mismatch for $file (expected $expected, got $actual)"
        return 1
    fi
    return 0
}

# halow_verify_manifest <manifest_file> <base_dir>
# manifest_file lines are standard `sha256sum` output: "<sha256>  <path>" (text mode,
# two spaces) or "<sha256> *<path>" (binary mode, one space + asterisk) — both are
# accepted, since different platforms' `sha256sum` default differently (confirmed the
# hard way: this add-on's own build.sh produced the asterisk form when first run under
# Windows Git Bash, and the plain two-space form under WSL2, for byte-identical input).
# `read` with its default whitespace splitting handles both forms identically. Blank
# lines and '#'-comments are ignored. Fails closed: any missing file or mismatch fails
# the whole check, and every failure is reported (not just the first).
halow_verify_manifest() {
    local manifest="$1" base_dir="$2" line sha rel ok=0 fail=0
    if [ ! -f "$manifest" ]; then
        halow_log_error "checksum: manifest not found: $manifest"
        return 1
    fi
    while IFS= read -r line; do
        case "$line" in
            ''|'#'*) continue ;;
        esac
        read -r sha rel <<< "$line"
        rel="${rel#\*}"
        rel="${rel#./}"
        if halow_verify_file_checksum "$base_dir/$rel" "$sha"; then
            ok=$((ok + 1))
        else
            fail=$((fail + 1))
        fi
    done < "$manifest"
    if [ "$fail" -ne 0 ]; then
        halow_log_error "checksum: $fail file(s) failed verification ($ok ok)"
        return 1
    fi
    halow_log_info "checksum: $ok file(s) verified against manifest"
    return 0
}

# halow_checksum_for <relative_name> [<manifest_file>]
# Looks up a single file's expected SHA-256 from a manifest (default
# HALOW_ARTIFACTS_DIR/MANIFEST.sha256), accepting either `sha256sum` output form (see
# halow_verify_manifest's own comment for why both must be accepted).
# Deliberately file-based, not an environment variable: s6-overlay runs `run` and
# `finish` as separate process invocations that do not share shell state, and rollback
# (called from either) must independently re-derive the same expected checksum every
# time, from the one artifact the image itself ships — never from a value that could
# have gone stale or missing between processes.
halow_checksum_for() {
    local name="$1" manifest="${2:-${HALOW_ARTIFACTS_DIR:?}/MANIFEST.sha256}"
    if [ ! -f "$manifest" ]; then
        halow_log_error "checksum: manifest not found: $manifest"
        return 1
    fi
    local sha
    sha="$(awk -v n="$name" '
        {
            file = $2
            sub(/^\*/, "", file)
            sub(/^\.\//, "", file)
            if (file == n) { print $1; found = 1; exit }
        }
        END { if (!found) exit 1 }
    ' "$manifest")" || {
        halow_log_error "checksum: no manifest entry for $name in $manifest"
        return 1
    }
    printf '%s\n' "$sha"
}
