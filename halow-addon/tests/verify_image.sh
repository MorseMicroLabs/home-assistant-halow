#!/usr/bin/env bash
# real ARM64 image verification: inspects a built image off-device,
# never the Green or any hardware.
#
# Separate from run_tests.sh (that suite is Docker-free by design), so it is not named
# test_*.sh. Run it after `ARTIFACT_BUNDLE_DIR=<bundle> BUILD_IMAGE=1 ./build.sh` has
# produced `morse-micro-halow-ap:local` (or name another image as the first argument).
#
# Every check is off-device: no module loading, no live networking, no Supervisor. The
# image's own entrypoint (s6-overlay) is always overridden so nothing is started; the
# in-image checks run the image's own bash, BusyBox, apk and python3:
#   tests/image_layout_check.sh            services, libraries, packages (incl. nft at the pinned version), user, setuid, udev
#   tests/image_status_check.sh            the status service's privilege drop and answers
#   tests/image_token_check.sh             under the real /init (the one run that is not
#                                          entrypoint-overridden; services masked): uid 990
#                                          cannot read the Supervisor token (+ a negative
#                                          control with /etc/cont-init.d masked)
#   tests/image_firmware_placement_check.sh firmware staging/removal under BusyBox (+ a
#                                          negative control against the historical defect)
#   tests/image_sentinel_check.sh          firmware search-path sentinel lifecycle
set -e
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${1:-morse-micro-halow-ap:local}"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
fail() { echo "ERROR: $*" >&2; exit 1; }
label() { docker image inspect "$IMAGE" --format "{{index .Config.Labels \"$1\"}}"; }

VERSION="$(awk '/^version:/ { gsub(/"/, "", $2); print $2; exit }' "$REPO_DIR/config.yaml")"
BASE="$(awk '$1 == "FROM" { print $2; exit }' "$REPO_DIR/Dockerfile")"
PINS="$(awk '/apk add/ {r = 1} r { line = $0; c = (line ~ /\\[[:space:]]*$/); sub(/\\[[:space:]]*$/, "", line); n = split(line, w, /[[:space:]]+/); for (i = 1; i <= n; i++) if (w[i] ~ /=/) printf "%s ", w[i]; if (!c) r = 0 }' "$REPO_DIR/Dockerfile")"
PINS="${PINS% }"
WANT_UID="$(grep -oE -- '-u [0-9]+' "$REPO_DIR/Dockerfile" | awk '{print $2; exit}')"
WANT_GID="$(grep -oE -- 'addgroup -S -g [0-9]+' "$REPO_DIR/Dockerfile" | awk '{print $4; exit}')"
[ -n "$VERSION" ] && [ -n "$BASE" ] && [ -n "$PINS" ] && [ -n "$WANT_UID" ] && [ -n "$WANT_GID" ] || fail "could not read the expected values from config.yaml/Dockerfile"

echo "=== image metadata ($IMAGE) ==="
docker image inspect "$IMAGE" --format 'Architecture={{.Architecture}} Os={{.Os}} Size={{.Size}}'
[ "$(docker image inspect "$IMAGE" --format '{{.Architecture}}/{{.Os}}')" = "arm64/linux" ] || fail "the image is not linux/arm64"
echo "asserted: image is linux/arm64"
[ "$(docker run --rm --platform linux/arm64 --entrypoint /bin/uname "$IMAGE" -m)" = "aarch64" ] || fail "a process in the image does not report aarch64"
echo "asserted: a process inside the image reports aarch64"
[ "$(label io.hass.type)/$(label io.hass.version)/$(label io.hass.arch)" = "app/$VERSION/aarch64" ] || fail "the io.hass labels are not app/$VERSION/aarch64"
echo "asserted: io.hass labels are app/$VERSION/aarch64"
[ "$(label org.opencontainers.image.title)" = "Morse Micro Wi-Fi HaLow Access Point for Home Assistant" ] || fail "the title label is not the product name"
case "$(label org.opencontainers.image.description)" in *"Home Assistant Green (aarch64)"*"Region: Australia only.") ;; *) fail "the description label does not name Home Assistant Green (aarch64) and end with the region statement" ;; esac
case "$(label org.opencontainers.image.description)" in *[Rr]elease\ candidate*|*[Ee]xperimental*) fail "the description label still carries release-candidate or Experimental wording" ;; esac
[ "$(label org.opencontainers.image.source)" = "https://github.com/MorseMicroLabs/home-assistant-halow" ] || fail "the source label is not the Morse Micro Labs repository address"
[ -z "$(label org.opencontainers.image.licenses)" ] || fail "an OCI license label is set; none is expected (see LICENSE, NOTICE and THIRD-PARTY-NOTICES.md)"
layers="$(docker image inspect "$IMAGE" --format '{{len .RootFS.Layers}}')"
[ "$layers" -le 8 ] || fail "the image has $layers layers; more than 8 lengthens the root overlay line of the container's mount table and has broken the BusyBox mount remount the app relies on (the tested predecessor has 8)"
echo "asserted: the image has $layers layers (at most 8)"
echo "asserted: labels carry the product name, Home Assistant Green (aarch64), the region statement and the repository address, with no release-candidate or Experimental wording"
[ "$(label io.halow.build.base)" = "$BASE" ] || fail "the build-input label io.halow.build.base is not the Dockerfile's base ($BASE); build with build.sh"
[ "$(label io.halow.build.packages)" = "$PINS" ] || fail "the build-input label io.halow.build.packages is not the Dockerfile's pins; build with build.sh"
[ "$(label io.halow.build.artifact-manifest-sha256)" = "$(sha256sum "$REPO_DIR/MANIFEST.sha256" | awk '{print $1}')" ] || fail "the image was built from a different artifact manifest"
echo "asserted: the image records its pinned build inputs (base digest, package pins, artifact manifest)"
env_list="$(docker image inspect "$IMAGE" --format '{{range .Config.Env}}{{println .}}{{end}}')"
grep -qx 'S6_SERVICES_GRACETIME=90000' <<< "$env_list" || fail "S6_SERVICES_GRACETIME is not 90000 in the image"
grep -qx 'S6_KILL_GRACETIME=5000' <<< "$env_list" || fail "S6_KILL_GRACETIME is not 5000 in the image"
echo "asserted: the s6 stop budgets are set in the image"
[ -z "$(docker image inspect "$IMAGE" --format '{{.Config.User}}')" ] || fail "the image's default user was changed (s6 must start as root)"
echo "asserted: the image starts as root (s6-overlay); only the status server drops privileges"

echo "=== a binary extracted from the image is genuinely ARM64 ==="
cid="$(docker create --platform linux/arm64 "$IMAGE")"
docker cp "${cid}:/opt/halow/artifacts/morse.ko" "$SCRATCH/morse.ko" >/dev/null
docker rm "$cid" >/dev/null
file "$SCRATCH/morse.ko"
readelf -h "$SCRATCH/morse.ko" | grep -E "Machine|Class|Data"
readelf -h "$SCRATCH/morse.ko" | grep -q 'AArch64' || fail "morse.ko is not an AArch64 object"

echo "=== in-image layout: services, libraries, packages, user, setuid, udev ==="
docker run --rm --platform linux/arm64 --network none --entrypoint /bin/bash \
    -v "$REPO_DIR/tests/image_layout_check.sh:/tmp/image_layout_check.sh:ro" \
    "$IMAGE" /tmp/image_layout_check.sh "$PINS" "$WANT_UID" "$WANT_GID"

echo "=== in-image status service: privilege drop, answers, refuses root ==="
docker run --rm --platform linux/arm64 --network none --entrypoint /bin/bash \
    -v "$REPO_DIR/tests/image_status_check.sh:/tmp/image_status_check.sh:ro" \
    "$IMAGE" /tmp/image_status_check.sh

echo "=== under the real s6-overlay /init: the status user cannot read the Supervisor token ==="
# A random canary stands in for the token. The services are masked (an empty tmpfs over
# /etc/services.d) so only s6-overlay itself and /etc/cont-init.d run; the check script is
# the container command, which s6 runs after cont-init.
canary="HALOWCANARY-$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
run_token_check() { # run_token_check <extra docker args...>
    docker run --rm --platform linux/arm64 --network none --tmpfs /etc/services.d \
        -e SUPERVISOR_TOKEN="$canary" -e HASSIO_TOKEN="$canary" \
        -v "$REPO_DIR/tests/image_token_check.sh:/tmp/image_token_check.sh:ro" \
        "$@" --entrypoint /init "$IMAGE" /bin/bash /tmp/image_token_check.sh
}
if ! run_token_check > "$SCRATCH/token.txt" 2>&1; then
    cat "$SCRATCH/token.txt" >&2; fail "the in-image token check failed under /init"
fi
grep -vE '^s6-rc: info|^/package/admin/s6-overlay/libexec/preinit: info|^s6-rc-compile: warning' "$SCRATCH/token.txt"
grep -qF 'cont-init: info: /etc/cont-init.d/00-restrict-container-environment exited 0' "$SCRATCH/token.txt" \
    || fail "s6-overlay did not run the cont-init hardening script before the container command"
grep -qF 'image_token_check: all passed' "$SCRATCH/token.txt" || fail "the token check did not report success"
if grep -qF "$canary" "$SCRATCH/token.txt"; then fail "the canary token appeared in the container output"; fi
echo "asserted: under /init, uid 990 cannot read the token; root still can through with-contenv"
echo "--- negative control: with /etc/cont-init.d masked, the same check must FAIL ---"
if run_token_check --tmpfs /etc/cont-init.d > "$SCRATCH/token_neg.txt" 2>&1; then
    cat "$SCRATCH/token_neg.txt" >&2; fail "the token check PASSED without the cont-init hardening; it proves nothing"
fi
grep -qF 'FAIL: uid 990 cannot read /run/s6/container_environment/SUPERVISOR_TOKEN' "$SCRATCH/token_neg.txt" \
    || { cat "$SCRATCH/token_neg.txt" >&2; fail "the negative control failed, but not because uid 990 could read the token"; }
echo "negative control confirmed: without the cont-init script uid 990 reads the token and the check fails."
echo "--- fail closed: a missing container environment stops the container before any service ---"
if docker run --rm --platform linux/arm64 --network none --tmpfs /etc/services.d -e S6_KEEP_ENV=1 \
        -e SUPERVISOR_TOKEN="$canary" --entrypoint /init "$IMAGE" /bin/true > "$SCRATCH/keepenv.txt" 2>&1; then
    cat "$SCRATCH/keepenv.txt" >&2; fail "with S6_KEEP_ENV=1 (no container environment directory) the container started its command anyway"
fi
grep -qF 'restrict-container-environment: ERROR' "$SCRATCH/keepenv.txt" \
    || { cat "$SCRATCH/keepenv.txt" >&2; fail "the S6_KEEP_ENV run stopped, but not because of the cont-init script"; }
echo "asserted: with S6_KEEP_ENV=1 the cont-init script fails and s6-overlay stops the container (S6_BEHAVIOUR_IF_STAGE2_FAILS=2)"

echo "=== the image's artifacts and manifest ==="
mkdir -p "$SCRATCH/img"
cid="$(docker create --platform linux/arm64 "$IMAGE")"
docker cp "${cid}:/opt/halow/artifacts/." "$SCRATCH/img/artifacts" >/dev/null
docker cp "${cid}:/usr/lib/halow/." "$SCRATCH/img/lib" >/dev/null
docker cp "${cid}:/usr/share/halow/." "$SCRATCH/img/share" >/dev/null
docker cp "${cid}:/etc/services.d/." "$SCRATCH/img/services" >/dev/null
docker cp "${cid}:/etc/cont-init.d/." "$SCRATCH/img/cont-init" >/dev/null
docker rm "$cid" >/dev/null
[ -f "$SCRATCH/img/artifacts/MANIFEST.sha256" ] || fail "MANIFEST.sha256 is not inside the image's /opt/halow/artifacts/ (it is a runtime dependency)"
diff -u "$REPO_DIR/MANIFEST.sha256" "$SCRATCH/img/artifacts/MANIFEST.sha256" || fail "the in-image MANIFEST.sha256 differs from this repository's"
echo "asserted: the in-image manifest is byte-identical to this repository's"
if ! sums="$(cd "$SCRATCH/img/artifacts" && sha256sum -c MANIFEST.sha256)"; then
    printf '%s\n' "$sums"; fail "an artifact in the image does not match the in-image manifest"
fi
printf '%s\n' "$sums"
grep -qE '^\./bcf/bcf_boardtype_0807\.bin: OK$' <<< "$sums" || fail "the nested BCF entry was not checked"
expected_files="$( (awk '{print $2}' "$REPO_DIR/MANIFEST.sha256"; echo ./MANIFEST.sha256) | sort -u)"
actual_files="$(cd "$SCRATCH/img/artifacts" && find . -type f | sort)"
if [ "$expected_files" != "$actual_files" ]; then
    diff <(printf '%s\n' "$expected_files") <(printf '%s\n' "$actual_files") >&2 || true
    fail "the files in /opt/halow/artifacts differ from the manifest's (plus the manifest itself)"
fi
echo "asserted: the image's artifact file list is exactly the manifest's"
for exe in hostapd_s1g hostapd_cli_s1g; do
    file "$SCRATCH/img/artifacts/$exe" | grep -q "ARM aarch64" || fail "$exe in the image is not an aarch64 executable"
done
echo "asserted: hostapd_s1g and hostapd_cli_s1g are aarch64 executables"
[ ! -e "$SCRATCH/img/artifacts/morse_cli" ] || fail "the removed helper program is in the image's artifacts directory"
echo "asserted: the removed helper program is not in the image"

echo "=== the add-on's own files in the image equal this repository's ==="
for pair in "rootfs/usr/lib/halow:lib" "rootfs/usr/share/halow:share" "rootfs/etc/services.d:services" "rootfs/etc/cont-init.d:cont-init"; do
    src="$REPO_DIR/${pair%%:*}" dst="$SCRATCH/img/${pair#*:}"
    if ! diff -r -x __pycache__ "$src" "$dst" >/dev/null; then
        diff -r -x __pycache__ "$src" "$dst" >&2 || true
        fail "${pair%%:*} in the image differs from this repository (a stale image?)"
    fi
done
[ ! -e "$SCRATCH/img/lib/udev_rule.sh" ] || fail "udev_rule.sh is in the image"
echo "asserted: /usr/lib/halow, /usr/share/halow, /etc/services.d and /etc/cont-init.d are identical to this repository's; no udev_rule.sh"

echo "=== in-image firmware placement/removal (BusyBox cp regression) ==="
docker run --rm --platform linux/arm64 --network none --entrypoint /bin/bash \
    -v "$REPO_DIR/tests/image_firmware_placement_check.sh:/tmp/image_firmware_placement_check.sh:ro" \
    "$IMAGE" /tmp/image_firmware_placement_check.sh

echo "=== in-image firmware search-path sentinel lifecycle ==="
docker run --rm --platform linux/arm64 --network none --entrypoint /bin/bash \
    -v "$REPO_DIR/tests/image_sentinel_check.sh:/tmp/image_sentinel_check.sh:ro" \
    "$IMAGE" /tmp/image_sentinel_check.sh

echo "=== negative control: the firmware check must FAIL against the historical broken firmware.sh ==="
BROKEN_FW="$SCRATCH/firmware_broken.sh"
sed 's/cp -p --/cp --preserve=mode --/' "$REPO_DIR/rootfs/usr/lib/halow/firmware.sh" > "$BROKEN_FW"
grep -qF -- '--preserve=mode' "$BROKEN_FW" && ! grep -qF -- 'cp -p --' "$BROKEN_FW" \
    || fail "could not reconstruct the historical broken firmware.sh; the negative control would prove nothing"
if docker run --rm --platform linux/arm64 --network none --entrypoint /bin/bash \
    -v "$REPO_DIR/tests/image_firmware_placement_check.sh:/tmp/image_firmware_placement_check.sh:ro" \
    -v "$BROKEN_FW:/usr/lib/halow/firmware.sh:ro" \
    "$IMAGE" /tmp/image_firmware_placement_check.sh > "$SCRATCH/negative.txt" 2>&1; then
    cat "$SCRATCH/negative.txt" >&2
    fail "the in-image firmware check PASSED against the known-broken firmware.sh"
fi
grep -qF 'unrecognized option' "$SCRATCH/negative.txt" || { cat "$SCRATCH/negative.txt" >&2; fail "the negative control failed, but not with BusyBox cp's 'unrecognized option'"; }
echo "negative control confirmed: fails closed with the historical BusyBox cp signature."

echo
echo "verify_image.sh: all checks passed."
