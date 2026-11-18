#!/usr/bin/env bash
# Final-release gate. Read-only: no network, no writes, no docker. It prints one line per
# gate, "PASS: [n] <name>" or "BLOCK: [n] <name>: <reason>", and exits 0 only when every
# gate passes (exit 1 otherwise, exit 2 on a usage error).
#
# It is NOT part of the normal development tests as a pass requirement: while the release
# decisions are open it is expected to BLOCK. Publication must not proceed while any gate
# BLOCKs. A PASS here is a mechanical file check only; it is not a legal conclusion and not
# approval to publish. Gate 4 refuses an internal release working list left in the tree.
#
# Usage:
#   tools/final_release_gate.sh [ROOT]     ROOT is the repository root (the folder that holds
#                                          halow-addon/, LICENSE, NOTICE, README.md). Default:
#                                          two levels above this script, which is correct in
#                                          both the private working tree and the Labs tree.
#   tools/final_release_gate.sh --list     print the gate names only
#   tools/final_release_gate.sh --assets DIR [--private-preparation] [ROOT]
#                                          DIR holds the corresponding-source release assets (gate 13
#                                          verifies them; HALOW_SOURCE_ASSETS_DIR does the same).
#                                          --private-preparation evaluates gates 1 to 13 and reports
#                                          gate 14 (the assets are published and reachable) as pending.
#
# Rule for gate 9 (copyright holder): "Copyright 2026 Morse Micro" is the confirmed, final
# copyright line. The gate BLOCKs unless NOTICE carries exactly that line as a whole line and
# REUSE.toml carries it as the copyright text of the application annotation, so the line
# cannot silently change or disappear.
set -o nounset -o pipefail

GATES=(
    "version-and-stage"
    "image-key"
    "unresolved-markers"
    "release-todo-removed"
    "license-files"
    "redistribution-records"
    "icon-and-logo"
    "development-wording"
    "copyright-holder"
    "docs-md"
    "security-reporting-route"
    "licenseref-treatment"
    "source-assets-prepared"
    "source-published"
)

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_usage() {
    echo "usage: final_release_gate.sh [--private-preparation] [--assets DIR] [ROOT | --list]" >&2
    exit 2
}
ASSETS_DIR="${HALOW_SOURCE_ASSETS_DIR:-}"; PREP_ONLY=0; ROOT_ARG=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --list)
            n=0
            for g in "${GATES[@]}"; do n=$((n + 1)); echo "[$n] $g"; done
            exit 0 ;;
        --assets) [ -n "${2:-}" ] || _usage; ASSETS_DIR="$2"; shift 2 ;;
        --private-preparation) PREP_ONLY=1; shift ;;
        -h|--help) _usage ;;
        *) [ -z "$ROOT_ARG" ] || _usage; ROOT_ARG="$1"; shift ;;
    esac
done
ROOT="${ROOT_ARG:-$_here/../..}"
if [ ! -d "$ROOT" ]; then
    echo "usage: ROOT is not a directory: $ROOT" >&2
    exit 2
fi
ROOT="$(cd "$ROOT" && pwd)"
ADDON="$ROOT/halow-addon"

APACHE_SHA="cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30"
GPL2_SHA="edaef632cbb643e4e7a221717a6c441a4c1a7c918e6e4d56debc3d8739b233f6"

BLOCKED=0
_n=0
_pass() { _n=$((_n + 1)); echo "PASS: [$_n] ${GATES[$((_n - 1))]}"; }
_block() { _n=$((_n + 1)); BLOCKED=$((BLOCKED + 1)); echo "BLOCK: [$_n] ${GATES[$((_n - 1))]}: $1"; }
# _result <reasons>: empty reasons means PASS.
_result() { if [ -z "$1" ]; then _pass; else _block "$1"; fi; }
# _add <var> <text>: append text to the named variable, separated by "; ".
_add() {
    local cur="${!1}"
    if [ -z "$cur" ]; then printf -v "$1" '%s' "$2"; else printf -v "$1" '%s; %s' "$cur" "$2"; fi
}
# Top-level scalar from config.yaml (quotes and trailing comment removed).
_top() {
    [ -f "$ADDON/config.yaml" ] || return 0
    awk -v k="$1" -F': *' '$1 == k { v = $2; sub(/[[:space:]]+#.*$/, "", v); gsub(/\r/, "", v); gsub(/^"|"$/, "", v); print v; exit }' "$ADDON/config.yaml"
}
# Files that ship to the public repository and carry customer or operator wording (gates 3 and 8):
# Markdown at any depth under docs/ and halow-addon/docs/, root and app-folder Markdown and YAML,
# translations, the Dockerfile and NOTICE. PROVENANCE.md (history) is excluded, and so is an internal
# release working list named RELEASE-TODO.md (gate 4 blocks that file on its own).
_public_files() {
    { find "$ROOT/docs" "$ADDON/docs" -type f -name '*.md' 2>/dev/null
      find "$ROOT" "$ADDON" -maxdepth 1 -type f \( -name '*.md' -o -name '*.yaml' \) 2>/dev/null
      find "$ADDON/translations" -type f -name '*.yaml' 2>/dev/null
      for f in "$ADDON/Dockerfile" "$ROOT/NOTICE"; do [ -f "$f" ] && echo "$f"; done; } \
    | grep -vE '/(RELEASE-TODO|PROVENANCE)\.md$' | sort -u
}
_sha() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }
_rel() { echo "${1#"$ROOT"/}"; }

# ---- 1. version and stage ---------------------------------------------------------------
r=""
ver="$(_top version)"; stg="$(_top stage)"
if [ ! -f "$ADDON/config.yaml" ]; then
    _add r "halow-addon/config.yaml is missing"
else
    [ "$ver" = "1.0.0" ] || _add r "version is '${ver:-none}', must be 1.0.0"
    [ "$stg" = "stable" ] || _add r "stage is '${stg:-none}', must be stable"
    if { [ "$ver" = "1.0.0" ] && [ "$stg" != "stable" ]; } || { [ "$ver" != "1.0.0" ] && [ "$stg" = "stable" ]; }; then
        _add r "mixed version/stage combination"
    fi
    if [ -f "$ADDON/Dockerfile" ] && [ "$ver" = "1.0.0" ]; then
        for lab in io.hass.version org.opencontainers.image.version; do
            lv="$(grep -oE "${lab//./\\.}=\"[^\"]*\"" "$ADDON/Dockerfile" | head -1 | sed 's/.*="//; s/"$//')"
            [ "$lv" = "1.0.0" ] || _add r "Dockerfile label $lab is '${lv:-none}', must be 1.0.0"
        done
    fi
fi
_result "$r"

# ---- 2. image key ---------------------------------------------------------------------------
r=""
if [ ! -f "$ADDON/config.yaml" ]; then
    _add r "halow-addon/config.yaml is missing"
else
    line="$(grep -E '^image:' "$ADDON/config.yaml" | head -1)"
    if [ -z "$line" ]; then
        _add r "no image: key in halow-addon/config.yaml"
    else
        val="$(printf '%s' "${line#image:}" | sed -E 's/[[:space:]]+#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//; s/^"//; s/"$//')"
        if [ -z "$val" ]; then
            _add r "image: key is empty"
        else
            case "$val" in
                *'[PENDING'*|*GHCR-DEPENDENT*|*TODO*|*TBD*|*'<'*|*'{'*|*'$'*|*' '*)
                    _add r "image: value contains an unresolved marker or a space ($val)" ;;
            esac
            # No tag and no digest: the last path segment must not contain ":" or "@".
            last="${val##*/}"
            case "$last" in
                *:*|*@*) _add r "image: value must have no tag or digest ($val); the version is the tag" ;;
            esac
        fi
    fi
fi
_result "$r"

# ---- 3. unresolved markers -------------------------------------------------------------------
r=""
files=()
while IFS= read -r f; do files+=("$f"); done < <(_public_files)
hits=""
for f in "${files[@]}"; do
    while IFS=: read -r ln _; do
        [ -n "$ln" ] && _add hits "$(_rel "$f"):$ln"
    done < <(tr -d '\r' < "$f" | grep -niE 'GHCR-DEPENDENT|\[PENDING')
done
[ -z "$hits" ] || _add r "GHCR-DEPENDENT or [PENDING markers at $hits"
_result "$r"

# ---- 4. an internal release working list (RELEASE-TODO.md) must not be in the tree being published ----
r=""
while IFS= read -r f; do
    [ -n "$f" ] && _add r "$(_rel "$f") exists (an internal release working list; it must not be published)"
done < <(find "$ROOT" -name RELEASE-TODO.md -not -path '*/.git/*' 2>/dev/null | sort)
_result "$r"

# ---- 5. license files and recorded hashes -------------------------------------------------------
r=""
for d in "$ROOT" "$ADDON"; do
    if [ "$d" = "$ROOT" ]; then p="."; else p="halow-addon"; fi
    for f in LICENSE NOTICE LICENSES/Apache-2.0.txt LICENSES/GPL-2.0-only.txt; do
        [ -f "$d/$f" ] || _add r "$p/$f is missing"
    done
    if [ -f "$d/LICENSES/Apache-2.0.txt" ] && [ "$(_sha "$d/LICENSES/Apache-2.0.txt")" != "$APACHE_SHA" ]; then
        _add r "$p/LICENSES/Apache-2.0.txt hash differs from the recorded one"
    fi
    if [ -f "$d/LICENSES/GPL-2.0-only.txt" ] && [ "$(_sha "$d/LICENSES/GPL-2.0-only.txt")" != "$GPL2_SHA" ]; then
        _add r "$p/LICENSES/GPL-2.0-only.txt hash differs from the recorded one"
    fi
done
_result "$r"

# ---- 6. redistribution records ---------------------------------------------------------------------
# Every provenance.psv row must have a recorded redistribution decision (field 9 present and not
# not-assessed, in any spelling; the file must have rows). SOURCE-OFFER.md must exist. The corresponding
# source has its own two gates: 13 (the source assets are completely prepared and verified, private
# preparation) and 14 (the source assets are actually published and reachable).
r=""
PSV="$ADDON/provenance.psv"
if [ ! -f "$PSV" ]; then
    _add r "halow-addon/provenance.psv is missing"
else
    cnt="$(tr -d '\r' < "$PSV" | grep -v '^#' | awk -F'|' 'NF >= 9 { n++; v = $9; gsub(/^[ \t]+|[ \t]+$/, "", v); v = tolower(v); gsub(/[ _]/, "-", v); if (v == "not-assessed" || v == "") c++ } END { print n + 0, c + 0 }')"
    rows="${cnt% *}"; na="${cnt#* }"
    [ "$rows" -gt 0 ] || _add r "provenance.psv has no data rows"
    [ "$na" -eq 0 ] || _add r "$na provenance.psv rows have redistribution not-assessed"
fi
[ -f "$ADDON/SOURCE-OFFER.md" ] || _add r "halow-addon/SOURCE-OFFER.md is missing"
_result "$r"

# ---- 7. icon.png and logo.png (existence and PNG signature only) -----------------------------------------
r=""
for f in icon.png logo.png; do
    if [ ! -f "$ADDON/$f" ]; then
        _add r "halow-addon/$f is missing"
    elif [ "$(head -c 8 "$ADDON/$f" | od -An -tx1 | tr -d ' \n')" != "89504e470d0a1a0a" ]; then
        _add r "halow-addon/$f is not a PNG file (signature mismatch)"
    else
        # IHDR width and height: big-endian 32-bit values at byte offsets 16 and 20.
        dims="$(od -An -tu1 -j16 -N8 "$ADDON/$f" | awk '{ print $1*16777216+$2*65536+$3*256+$4, $5*16777216+$6*65536+$7*256+$8 }')"
        w="${dims% *}"; h="${dims#* }"
        if [ "$f" = "icon.png" ]; then
            { [ "$w" = "128" ] && [ "$h" = "128" ]; } || _add r "halow-addon/icon.png is ${w}x${h}, must be 128x128"
        else
            { [ "${w:-0}" -ge 1 ] && [ "$w" -le 250 ] && [ "${h:-0}" -ge 1 ] && [ "$h" -le 100 ]; } || _add r "halow-addon/logo.png is ${w}x${h}, must be at most 250x100"
        fi
    fi
done
_result "$r"

# ---- 8. development wording ----------------------------------------------------------------------------
# Scans every Markdown file at any depth under docs/ and halow-addon/docs/, the root and app-folder
# Markdown files (except PROVENANCE.md, which records history, and an internal RELEASE-TODO.md, which
# gate 4 blocks on its own), the YAML files, the
# Dockerfile and NOTICE. Case-insensitive; "development-build" with a hyphen counts too.
r=""
files=()
while IFS= read -r f; do files+=("$f"); done < <(_public_files)
hits=""
for f in "${files[@]}"; do
    while IFS=: read -r ln _; do
        [ -n "$ln" ] && _add hits "$(_rel "$f"):$ln"
    done < <(tr -d '\r' < "$f" | grep -niE 'development[ -]build|not production-ready')
done
[ -z "$hits" ] || _add r "development wording at $hits"
_result "$r"

# ---- 9. copyright holder ------------------------------------------------------------------------------------
r=""
CONFIRMED_COPYRIGHT="Copyright 2026 Morse Micro"
if [ ! -f "$ROOT/NOTICE" ]; then
    _add r "NOTICE is missing"
elif ! tr -d '\r' < "$ROOT/NOTICE" | grep -qxF "$CONFIRMED_COPYRIGHT"; then
    _add r "NOTICE does not carry the confirmed line '$CONFIRMED_COPYRIGHT' as a whole line"
fi
if [ ! -f "$ROOT/REUSE.toml" ]; then
    _add r "REUSE.toml is missing"
elif ! tr -d '\r' < "$ROOT/REUSE.toml" | grep -qE "^[[:space:]]*SPDX-FileCopyrightText[[:space:]]*=[[:space:]]*\"$CONFIRMED_COPYRIGHT\"[[:space:]]*$"; then
    _add r "REUSE.toml does not carry SPDX-FileCopyrightText = \"$CONFIRMED_COPYRIGHT\""
fi
_result "$r"

# ---- 10. DOCS.md ---------------------------------------------------------------------------------------------------
r=""
[ -s "$ADDON/DOCS.md" ] || _add r "halow-addon/DOCS.md is absent or empty"
_result "$r"

# ---- 11. security reporting route ----------------------------------------------------------------------------------
r=""
SEC_URL="https://www.morsemicro.com/policy/security-disclosure"
if [ ! -f "$ROOT/SECURITY.md" ]; then
    _add r "SECURITY.md is absent at the repository root"
elif ! grep -qF "$SEC_URL" "$ROOT/SECURITY.md"; then
    _add r "SECURITY.md does not name the security-disclosure form $SEC_URL"
fi
_result "$r"

# ---- 12. LicenseRef treatment ----------------------------------------------------------------------------------------
# Treatment-neutral. If REUSE.toml still uses a LicenseRef- identifier (in a non-comment SPDX-License-Identifier
# line), the approved text must be recorded at LICENSES/<id>.txt (the standard REUSE location; empty files do not
# count). If the annotation is changed or removed so that no LicenseRef- id remains, this gate passes. It says
# nothing about what the approved treatment is, and it is not a REUSE compliance check.
r=""
if [ -f "$ROOT/REUSE.toml" ]; then
    missing=""
    while read -r id; do
        [ -n "$id" ] || continue
        [ -s "$ROOT/LICENSES/$id.txt" ] || _add missing "$id"
    done < <(tr -d '\r' < "$ROOT/REUSE.toml" | grep -E '^[[:space:]]*SPDX-License-Identifier' | grep -oE 'LicenseRef-[A-Za-z0-9.-]+' | sort -u)
    [ -z "$missing" ] || _add r "REUSE.toml still uses LicenseRef id(s) with no approved text at LICENSES/<id>.txt: $missing (record the approved treatment: add the text, or change or remove the annotation)"
fi
_result "$r"

# ---- 13. source assets prepared and verified (private preparation) ------------------------------------------
# The complete corresponding-source package exists as local files that match the committed manifest
# source-assets/ASSETS.psv (size, sha256, archive member), the release-asset names and addresses are
# deterministic, and SOURCE-OFFER.md names every asset. The gate needs the directory that holds the
# assets (--assets DIR): without it the assets are not verified and the gate BLOCKs. It says nothing
# about publication: gate 14 does that.
r=""
MAN="$ADDON/source-assets/ASSETS.psv"
STATUS_FILE="$ADDON/source-assets/PUBLICATION-STATUS"
status_line=""
[ -f "$STATUS_FILE" ] && status_line="$(tr -d '\r' < "$STATUS_FILE" | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$' | grep '^status:' | head -n1)"
# The assets that must be in the set (the completeness of the set is pinned here, not only in the manifest).
# HALOW_REQUIRED_SOURCE_ASSETS replaces the list; it exists only so that the tests can use small fixture sets.
REQUIRED_ASSETS="${HALOW_REQUIRED_SOURCE_ASSETS:-morse-driver-source-2.1.0.tar.gz kernel-module-build-material-1.0.0.tar.xz kernel-prep.sh linux-6.18.58.tar.xz haos-operating-system-18.4.tar.gz buildroot-d2b75e05.tar.gz hostap-source-2.1.0.tar.gz hostapd-relink-material-1.0.0.tar.xz libnl-3.11.0.tar.gz glibc-2.41-5dd252cf.tar.gz alpine-3.23-copyleft-sources-1.0.0.tar SOURCE-INDEX.md}"
have_names=" "
if [ ! -f "$MAN" ]; then
    _add r "halow-addon/source-assets/ASSETS.psv is missing"
else
    want_base="https://github.com/MorseMicroLabs/home-assistant-halow/releases/download/v1.0.0/"
    got_base="$(tr -d '\r' < "$MAN" | sed -n 's/^# url_base: *//p' | head -n1)"
    [ "$got_base" = "$want_base" ] || _add r "ASSETS.psv url_base is '${got_base:-none}', must be $want_base"
    nrows=0
    while IFS='|' read -r name size sha covers lic member kind note extra; do
        name="$(echo "$name" | xargs)"; size="$(echo "$size" | xargs)"; sha="$(echo "$sha" | xargs)"
        [ -n "$name" ] || continue
        nrows=$((nrows + 1)); have_names="$have_names$name "
        [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || _add r "asset name '$name' is not URL-safe"
        [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -gt 0 ] || _add r "asset $name has no valid size"
        [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || _add r "asset $name has no valid sha256"
        [ -z "${extra:-}" ] || _add r "asset $name has too many fields"
        if [ -f "$ADDON/SOURCE-OFFER.md" ] && ! grep -qF -- "$name" "$ADDON/SOURCE-OFFER.md"; then
            _add r "SOURCE-OFFER.md does not name the asset $name"
        fi
    done < <(tr -d '\r' < "$MAN" | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$')
    [ "$nrows" -gt 0 ] || _add r "ASSETS.psv has no asset rows"
    if [ -f "$ADDON/SOURCE-OFFER.md" ] && ! grep -qF -- "$want_base" "$ADDON/SOURCE-OFFER.md"; then
        _add r "SOURCE-OFFER.md does not state the release-asset address $want_base"
    fi
    for req in $REQUIRED_ASSETS; do
        case "$have_names" in *" $req "*) : ;; *) _add r "ASSETS.psv does not list the required asset $req" ;; esac
    done
    if [ -f "$ADDON/SOURCE-OFFER.md" ]; then
        so="$(tr -d '\r' < "$ADDON/SOURCE-OFFER.md" | tr '\n' ' ' | tr -s ' ' | tr '[:upper:]' '[:lower:]')"
        for ph in "not yet supplied" "nothing is archived" "has not been publicly released" "private until" \
                  "no written offer of source has been published" "(is|are) pending" "pending the" \
                  "(has|have) not (yet )?been (decided|made)" "not yet decided"; do
            if printf '%s\n' "$so" | grep -qE "$ph"; then _add r "SOURCE-OFFER.md still says: $ph"; fi
        done
        # While the assets are only prepared, no text may say that they are already published.
        if [ "$status_line" != "status: published" ] && printf '%s\n' "$so" | grep -qE "(is|are|has been|have been) published"; then
            _add r "SOURCE-OFFER.md says the source is published while PUBLICATION-STATUS says it is not"
        fi
    fi
fi
[ -f "$ADDON/source-assets/SOURCE-INDEX.md" ] || _add r "halow-addon/source-assets/SOURCE-INDEX.md is missing"
[ -f "$ADDON/source-offer/kernel-prep.sh" ] || _add r "halow-addon/source-offer/kernel-prep.sh is missing"
case "$status_line" in
    "status: prepared"|"status: published") : ;;
    *) _add r "halow-addon/source-assets/PUBLICATION-STATUS must hold 'status: prepared' or 'status: published'" ;;
esac
if [ -z "$ASSETS_DIR" ]; then
    _add r "the local source assets were not verified (run the gate with --assets DIR)"
elif [ ! -d "$ASSETS_DIR" ]; then
    _add r "assets directory $ASSETS_DIR does not exist"
elif [ -f "$MAN" ]; then
    if out="$(bash "$_here/verify_source_assets.sh" --addon "$ADDON" "$ASSETS_DIR" 2>&1)"; then :; else
        _add r "source asset verification failed: $(printf '%s\n' "$out" | grep -E '^(FAIL|ERROR)' | head -n3 | paste -sd' ')"
    fi
fi
_result "$r"

# ---- 14. source assets published and reachable ------------------------------------------------------------
# Offline, this gate reads only the recorded publication status. 'status: published' is set by hand,
# after tools/final_publication_check.sh has confirmed from outside that every asset address answers
# with the recorded size. While the status is 'prepared' the gate BLOCKs. In --private-preparation mode
# it is reported as pending and does not count.
PUB_STATE="pending"
pub_reason=""
if [ "$status_line" = "status: published" ]; then
    rec_sha="$(tr -d '\r' < "$STATUS_FILE" | sed -n 's/^manifest-sha256: *//p' | head -n1)"
    cur_sha="$(_sha "$MAN")"
    if [ -n "$cur_sha" ] && [ "$rec_sha" = "$cur_sha" ]; then
        PUB_STATE="published"
    else
        pub_reason="PUBLICATION-STATUS says published but its manifest-sha256 line ('${rec_sha:-missing}') is not the sha256 of the current ASSETS.psv (${cur_sha:-unreadable}); run tools/final_publication_check.sh and record the lines it prints"
    fi
fi
if [ "$PREP_ONLY" -eq 1 ]; then
    _n=$((_n + 1))
    echo "PENDING: [$_n] ${GATES[$((_n - 1))]}: not evaluated in --private-preparation mode (publication status: ${status_line:-unknown})"
elif [ "$PUB_STATE" = "published" ]; then
    _pass
else
    _block "${pub_reason:-the source assets are not recorded as published (PUBLICATION-STATUS says '${status_line:-missing}'); run tools/final_publication_check.sh after they are reachable, then record the lines it prints}"
fi

if [ "$PREP_ONLY" -eq 1 ]; then
    total=$(( ${#GATES[@]} - 1 ))
    echo "final_release_gate (private preparation): $((total - BLOCKED))/$total gates pass; gate ${#GATES[@]} (publication) is pending"
    if [ "$BLOCKED" -eq 0 ]; then
        echo "RESULT: private preparation complete; publication is not done (mechanical checks only; not approval to publish)"
        exit 0
    fi
    echo "RESULT: BLOCKED ($BLOCKED gates)"
    exit 1
fi
echo "final_release_gate: $((${#GATES[@]} - BLOCKED))/${#GATES[@]} gates pass"
if [ "$BLOCKED" -eq 0 ]; then
    echo "RESULT: all gates pass (mechanical checks only; not approval to publish)"
    exit 0
fi
echo "RESULT: BLOCKED ($BLOCKED gates)"
exit 1
