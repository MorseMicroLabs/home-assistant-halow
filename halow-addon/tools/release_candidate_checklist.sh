#!/usr/bin/env bash
# Release checklist. Off-device only: it never contacts a
# Home Assistant system and changes nothing.
#
# preflight   Checks that can run on a build machine: the release version and
#               its labels, the manifest invariants, the kernel guard manifest for the
#               target Home Assistant OS release, the changelog entry, the built image's
#               labels (when HALOW_RC_IMAGE names an image), the license files that must exist and the repository file that must not exist
#               yet, and (when HALOW_RC_RUN_TESTS=1) the whole off-device test suite.
#
# Usage:
#   tools/release_candidate_checklist.sh preflight
#   tools/release_candidate_checklist.sh            (the same)
#
# Environment (all optional):
#   HALOW_RC_TARGET_RELEASE  kernel release string of the target Home Assistant OS release
#                            (the text "uname -r" prints there). Default 6.18.58-haos, which
#                            is Home Assistant OS 18.4. The guard manifest must carry all of
#                            that release's rows.
#   HALOW_RC_IMAGE           an image built off-device (name:tag or id) whose labels are
#                            checked and whose id is printed for the record. It is a
#                            check aid only: the Supervisor pulls the published image named
#                            by the image key, so record the registry digest after a push
#                            (see docs/LOCAL-IMAGE-BUILD.md).
#   HALOW_SOURCE_ASSETS_DIR  the directory that holds the corresponding-source release assets; when
#                            set, tools/verify_source_assets.sh checks them against
#                            source-assets/ASSETS.psv (without it the check is reported as NOT CHECKED).
#   HALOW_RC_RUN_TESTS=1     run tests/run_tests.sh and report its result. Without it the
#                            suite status is reported as NOT CHECKED.
#
# Exit status of preflight: 0 when no check failed (NOT CHECKED items are listed and do not
# fail the run, but they are not passes); 1 when any check failed.
set -o nounset -o pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADDON="$(cd "$_here/.." && pwd)"
CONFIG="$ADDON/config.yaml"
DOCKERFILE="$ADDON/Dockerfile"
GUARD_MANIFEST="${HALOW_GUARD_MANIFEST:-$ADDON/rootfs/usr/share/halow/guard_manifest.psv}"
CHANGELOG="$ADDON/CHANGELOG.md"
DEFAULT_TARGET_RELEASE="6.18.58-haos"

# The release version. The manifest, the Dockerfile labels, the README and the changelog must
# all name it. The earlier tested release candidate (0.4.0-rc.1) is history, not a valid value.
RELEASE_VERSION="1.0.0"

PASS=0; FAIL=0; NOTCHECKED=0
pass() { PASS=$((PASS + 1)); echo "  PASS         $*"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL         $*"; }
nc()   { NOTCHECKED=$((NOTCHECKED + 1)); echo "  NOT CHECKED  $*"; }

top() { awk -v k="$1" -F': *' '$1 == k { v = $2; sub(/[[:space:]]+#.*$/, "", v); gsub(/^"|"$/, "", v); print v; exit }' "$CONFIG"; }

preflight() {
    echo "== release: off-device preflight =="
    echo "-- version pair --"
    local version
    version="$(top version)"
    echo "  config.yaml version: ${version:-<none>}   (release version: $RELEASE_VERSION)"
    if [ "$version" = "$RELEASE_VERSION" ]; then
        pass "the manifest version is the release version"
    else
        fail "the manifest version '$version' is not $RELEASE_VERSION"
    fi
    if [ "$(top stage)" = "stable" ]; then
        pass "stage: stable"
    else
        fail "stage is '$(top stage)', not stable"
    fi
    if grep -qF "io.hass.version=\"$version\"" "$DOCKERFILE" \
       && grep -qF "org.opencontainers.image.version=\"$version\"" "$DOCKERFILE"; then
        pass "both Dockerfile version labels equal the manifest version"
    else
        fail "a Dockerfile version label does not equal the manifest version"
    fi
    if grep -qF "\`$version\`" "$ADDON/README.md" 2>/dev/null; then
        pass "README.md names the same version"
    else
        fail "README.md does not name version $version"
    fi
    if grep -qE "^## \[?${version//./\\.}\]?( |$)" "$CHANGELOG" 2>/dev/null; then
        pass "CHANGELOG.md has an entry for $version"
    else
        fail "CHANGELOG.md has no entry for $version"
    fi
    if grep -qx "  - \"$version\"" "$CONFIG"; then
        fail "breaking_versions lists the release version itself (decide that deliberately)"
    else
        pass "breaking_versions does not list the release version"
    fi

    echo "-- manifest invariants --"
    [ "$(top boot)" = "auto" ] && pass "boot: auto" || fail "boot is '$(top boot)', not auto"
    grep -qE '^  - aarch64$' "$CONFIG" && pass "arch lists aarch64" || fail "arch does not list aarch64"
    grep -qE '^  - green$' "$CONFIG" && pass "machine lists green" || fail "machine does not list green"
    local image
    image="$(top image)"
    if [ -z "$image" ]; then
        fail "no image key (the app cannot be built from the repository alone; the image key is required)"
    elif [[ "${image##*/}" == *:* ]]; then
        fail "the image value carries a tag ('$image'); the tag is always the version"
    else
        pass "image value has no tag: $image"
    fi
    if { sed -n "1,6p" "$CONFIG"; sed -n "/^description:/,/^stage:/p" "$CONFIG"; } | grep -qiE "development build|not production-ready"; then
        fail "the config.yaml header or description still carries development-build wording"
    else
        pass "the config.yaml header and description carry no development-build wording"
    fi

    echo "-- kernel guard manifest for the target release --"
    if [ ! -s "$GUARD_MANIFEST" ]; then
        fail "guard manifest missing or empty: $GUARD_MANIFEST"
    else
        local releases
        releases="$(awk -F'|' '$1 == "release" { printf "%s ", $2 }' "$GUARD_MANIFEST")"
        echo "  releases in the guard manifest: ${releases:-<none>}"
        {
            local t="${HALOW_RC_TARGET_RELEASE:-$DEFAULT_TARGET_RELEASE}" kind n missing=""
            echo "  target kernel release: $t (default $DEFAULT_TARGET_RELEASE; HALOW_RC_TARGET_RELEASE overrides)"
            for kind in release:1 kernel_build:1 kernel_banner:1 kernel_config:1 host_module:3 artifact:2; do
                n="$(awk -F'|' -v r="$t" -v k="${kind%%:*}" '$1 == k && $2 == r { c++ } END { print c + 0 }' "$GUARD_MANIFEST")"
                [ "$n" -eq "${kind##*:}" ] || missing="$missing ${kind%%:*}(found $n, need ${kind##*:})"
            done
            if [ -z "$missing" ]; then
                pass "guard manifest carries the full row set for $t (release, kernel_build, kernel_banner, kernel_config, 3 host_module, 2 artifact)"
            else
                fail "guard manifest row set for $t is incomplete or duplicated:$missing"
            fi
        }
    fi

    echo "-- license files present, repository file not yet present --"
    local f bad=0
    for f in LICENSE.md LICENSE.txt NOTICE.md NOTICE.txt repository.yaml repository.yml repository.json; do
        if [ -e "$ADDON/$f" ]; then fail "$f exists in the product tree"; bad=1; fi
        case "$f" in repository.yaml) : ;; *) if [ -e "$ADDON/../$f" ]; then fail "$f exists at the repository root"; bad=1; fi ;; esac
    done
    [ "$bad" -eq 0 ] && pass "no stray repository file and no stray LICENSE or NOTICE variant (repository.yaml belongs only at the root of the Labs tree)"
    for f in LICENSE NOTICE; do
        if [ -s "$ADDON/$f" ]; then pass "$f is present in the product tree"; else fail "$f is missing from the product tree"; fi
    done

    echo "-- staged artifacts --"
    if [ -f "$ADDON/MANIFEST.sha256" ]; then
        pass "artifact manifest present (sha256 $(sha256sum "$ADDON/MANIFEST.sha256" | awk '{print $1}'))"
    else
        fail "MANIFEST.sha256 missing"
    fi
    if [ -d "$ADDON/artifacts" ] && [ -f "$ADDON/MANIFEST.sha256" ]; then
        if (cd "$ADDON/artifacts" && find . -type f ! -name '*.actual' | sort | xargs sha256sum | awk '{ sub(/ \*/, "  "); print }' | diff -q - "$ADDON/MANIFEST.sha256" >/dev/null 2>&1); then
            pass "artifacts/ matches the tracked manifest"
        else
            fail "artifacts/ is missing or differs from the tracked manifest (run build.sh)"
        fi
    else
        nc "artifacts/ is not staged in this tree"
    fi

    echo "-- built image --"
    if [ -z "${HALOW_RC_IMAGE:-}" ]; then
        nc "set HALOW_RC_IMAGE to a locally built image to check its labels"
    elif ! command -v docker >/dev/null 2>&1; then
        nc "docker not found; the image labels were not checked"
    else
        _lab() { docker image inspect --format "{{ index .Config.Labels \"$1\" }}" "$HALOW_RC_IMAGE" 2>/dev/null; }
        local arch
        arch="$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$HALOW_RC_IMAGE" 2>/dev/null)"
        if [ -z "$arch" ]; then
            fail "image '$HALOW_RC_IMAGE' not found"
        else
            echo "  image id (record this): $(docker image inspect --format '{{.Id}}' "$HALOW_RC_IMAGE")"
            [ "$arch" = "linux/arm64" ] && pass "image is linux/arm64" || fail "image platform is $arch"
            [ "$(_lab io.hass.version)" = "$version" ] && pass "image io.hass.version equals the manifest version" || fail "image io.hass.version is '$(_lab io.hass.version)'"
            [ "$(_lab org.opencontainers.image.version)" = "$version" ] && pass "image OCI version label equals the manifest version" || fail "image OCI version label is '$(_lab org.opencontainers.image.version)'"
            [ "$(_lab io.hass.arch)" = "aarch64" ] && pass "image io.hass.arch is aarch64" || fail "image io.hass.arch is '$(_lab io.hass.arch)'"
            [ "$(_lab io.halow.build.version)" = "$version" ] && pass "image build-version label equals the manifest version" || fail "image io.halow.build.version is '$(_lab io.halow.build.version)'"
            [ -n "$(_lab io.halow.build.artifact-manifest-sha256)" ] && pass "image records the artifact manifest checksum" || fail "image lacks the artifact manifest checksum label"
        fi
    fi

    echo "-- corresponding-source assets --"
    if [ -n "${HALOW_SOURCE_ASSETS_DIR:-}" ]; then
        if _sv="$(bash "$ADDON/tools/verify_source_assets.sh" --addon "$ADDON" "$HALOW_SOURCE_ASSETS_DIR" 2>&1)"; then
            pass "the source assets in $HALOW_SOURCE_ASSETS_DIR match source-assets/ASSETS.psv ($(printf '%s\n' "$_sv" | tail -n1))"
        else
            fail "the source assets do not match source-assets/ASSETS.psv"; printf '%s\n' "$_sv" | grep '^FAIL' | head -n 5 | sed 's/^/    | /'
        fi
    else
        nc "set HALOW_SOURCE_ASSETS_DIR to the source-asset directory to verify the assets"
    fi

    echo "-- publication status of the source assets --"
    _ps="$(grep '^status:' "$ADDON/source-assets/PUBLICATION-STATUS" 2>/dev/null | head -n1)"
    case "$_ps" in
        "status: published") pass "the source assets are recorded as published (gate 14 also checks the manifest checksum)" ;;
        *) nc "the source assets are recorded as '${_ps:-unknown}': gate 14 (published) stays blocked until tools/final_publication_check.sh passes after the public release; run tools/final_release_gate.sh --private-preparation --assets DIR for gates 1 to 13" ;;
    esac

    echo "-- off-device test suite --"
    if [ "${HALOW_RC_RUN_TESTS:-0}" = "1" ]; then
        if (cd "$ADDON/tests" && ./run_tests.sh >/tmp/halow_rc_suite.$$ 2>&1); then
            pass "tests/run_tests.sh passed ($(tail -n1 /tmp/halow_rc_suite.$$))"
        else
            fail "tests/run_tests.sh failed (tail follows)"; tail -n 8 /tmp/halow_rc_suite.$$ | sed 's/^/    | /'
        fi
        rm -f /tmp/halow_rc_suite.$$
    else
        nc "suite not run; set HALOW_RC_RUN_TESTS=1 to run tests/run_tests.sh (use a native Linux copy, not a mounted Windows path)"
    fi

    echo
    echo "preflight: $PASS passed, $FAIL failed, $NOTCHECKED not checked"
    [ "$NOTCHECKED" -eq 0 ] || echo "A NOT CHECKED item is not a pass; resolve each before the release."
    [ "$FAIL" -eq 0 ]
}

case "${1:-all}" in
    preflight|all) preflight ;;
    *) echo "usage: $0 [preflight]" >&2; exit 2 ;;
esac
