#!/usr/bin/env bash
# Static packaging checks (no Docker needed):
#   - the Dockerfile pins the base image by digest and every package to an exact version,
#     has no unpinned `apk add`, no `latest`, no build-argument base, no ADD;
#   - the unprivileged status user is created with fixed ids, no shell and no home, and no
#     setuid or file-capability binary is added;
#   - the status server is only ever started through s6-setuidgid as that user;
#   - udev is gone from the manifest, the image and the code;
#   - the manifest has no secret default;
#   - the artifacts directory contract: build.sh requires ARTIFACT_BUNDLE_DIR, verifies the
#     bundle, stages exactly the manifest's files, and refuses an unpinned Dockerfile (run
#     for real against a throw-away copy and a dummy bundle, never against this tree).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh

echo "== test_packaging =="

DF="../Dockerfile"
ADDON=".."
DF_CODE="$(sed -E 's/^[[:space:]]*#.*$//' "$DF" | grep -v '^[[:space:]]*$')"
# Instructions with their continuation lines joined.
DF_JOINED="$(awk '{ line = $0; if (line ~ /^[[:space:]]*#/) next; if (sub(/\\[[:space:]]*$/, "", line)) { buf = buf line " "; next } print buf line; buf = "" }' "$DF")"

echo "-- base image --"
assert_eq "1" "$(grep -cE '^FROM[[:space:]]' <<< "$DF_CODE")" "exactly one FROM"
from="$(awk '$1 == "FROM" { print $2 }' <<< "$DF_CODE")"
assert_success "the base image is pinned by a sha256 digest" bash -c '[[ $0 =~ ^ghcr\.io/home-assistant/base:3\.23@sha256:[0-9a-f]{64}$ ]]' "$from"
assert_eq "ghcr.io/home-assistant/base:3.23@sha256:1550b137f45bbb61f932a5ec97265c1d8594ddc4a986b127fb06a5c8c4bcaa6d" "$from" "the base digest is the one this add-on was built and tested with"
assert_failure "no build argument can replace the base (no BUILD_FROM)" grep -q 'BUILD_FROM' <<< "$DF_CODE"
assert_failure "no 'latest' tag anywhere in the instructions" grep -qi 'latest' <<< "$DF_CODE"
assert_failure "no ADD instruction (COPY only)" grep -qE '^ADD[[:space:]]' <<< "$DF_CODE"

echo "-- packages --"
apk_lines="$(grep -E '(^|[[:space:]&;])apk[[:space:]]' <<< "$DF_JOINED")"
assert_eq "1" "$(grep -c . <<< "$apk_lines")" "exactly one apk instruction"
assert_success "apk add uses --no-cache" grep -q 'apk add --no-cache' <<< "$apk_lines"
assert_failure "no apk upgrade, update or cache use" grep -qE 'apk (upgrade|update|cache)' <<< "$DF_JOINED"
assert_failure "no pip, curl or wget in the build" grep -qE '(^|[[:space:]])(pip3?|curl|wget)[[:space:]]' <<< "$DF_JOINED"
pkgs="$(sed -E 's/.*apk add --no-cache[[:space:]]+//; s/[[:space:]]*&&.*$//' <<< "$apk_lines" | tr -s ' ' '\n' | grep -v '^$' | sort | tr '\n' ' ')"
assert_success "the install log and the generated machine id are removed in the same step (reproducibility)" \
    grep -qE 'apk add .* && rm -f /var/log/apk.log /etc/machine-id /var/lib/dbus/machine-id( |$)' <<< "$apk_lines"
unpinned=""
for p in $pkgs; do [[ $p =~ ^[a-z0-9][a-z0-9.+_-]*=[0-9][0-9a-z._]*-r[0-9]+$ ]] || unpinned="$unpinned $p"; done
assert_eq "" "$unpinned" "every apk package is pinned to an exact version-release"
assert_eq "dbus=1.16.2-r1 dnsmasq=2.91-r1 iproute2=6.17.0-r0 iptables=1.8.11-r1 kmod=34.2-r1 nftables=1.1.5-r2 python3=3.12.16-r0 " "$pkgs" "the package set and versions are exactly the verified Alpine 3.23 pins"
assert_success "the Dockerfile says exact pins are only reproducible while Alpine serves them" grep -qi "reproducible only while the Alpine repository still serves" "$DF"
assert_success "the Dockerfile names prebuilt, tagged images as the answer" grep -qi "prebuilt, tagged" "$DF"

echo "-- the unprivileged status user --"
user_line="$(grep -E 'adduser' <<< "$DF_JOINED")"
assert_success "a fixed-gid group halowstatus is created" grep -qE 'addgroup -S -g [0-9]+ halowstatus' <<< "$DF_JOINED"
assert_success "the user halowstatus has a fixed uid" grep -qE 'adduser .*-u [0-9]+ .*halowstatus$|adduser .*-u [0-9]+ .*halowstatus[[:space:]]' <<< "$user_line"
assert_success "the user has no login shell" grep -qE -- '-s /sbin/nologin' <<< "$user_line"
assert_success "no home directory is created (-H)" grep -qE -- '(^|[[:space:]])-[A-Za-z]*H' <<< "$user_line"
uid="$(grep -oE -- '-u [0-9]+' <<< "$user_line" | awk '{print $2}')"
gid="$(grep -oE -- 'addgroup -S -g [0-9]+' <<< "$DF_JOINED" | awk '{print $4}')"
assert_success "uid and gid are non-zero" test "${uid:-0}" -gt 0 -a "${gid:-0}" -gt 0
status_user="$(sed -n 's/^: "\${HALOW_STATUS_USER:=\([a-z_]*\)}"$/\1/p' ../rootfs/usr/lib/halow/constants.sh)"
assert_eq "halowstatus" "$status_user" "the code's status user is the user the image creates"
assert_failure "no setuid/setgid bit is set by the build" grep -qE 'chmod[[:space:]]+([ugoa]*\+[a-z]*s|[0-7]?[2-7][0-7]{3})' <<< "$DF_JOINED"
assert_success "the setuid bit the dbus package sets on its unused activation helper is removed" \
    grep -qE '&& chmod u-s,g-s /usr/libexec/dbus-daemon-launch-helper$' <<< "$apk_lines"
assert_failure "no file capability is set by the build" grep -qE '(setcap|cap_[a-z_]+[+=])' <<< "$DF_JOINED"
assert_failure "the image's default user is not changed (s6 must start as root)" grep -qE '^USER[[:space:]]' <<< "$DF_CODE"

echo "-- the status server only ever runs as that user --"
mapfile -t CODE_FILES < <(find ../rootfs -type f \( -name '*.sh' -o -name run -o -name finish -o -name '*.py' \) | sort)
refs="$(grep -l 'status_server\.py' "${CODE_FILES[@]}" 2>/dev/null | xargs -r -n1 basename | sort -u | tr '\n' ' ')"
assert_success "status_server.py is referenced only by its launcher, itself and the manager's process-identity check" bash -c '[[ "$0" == "launcher.sh manager.sh " || "$0" == "launcher.sh manager.sh status_server.py " ]]' "$refs"
assert_failure "the manager only compares the server's name with a command line: it never starts or signals it by that name" \
    bash -c 'grep -n "status_server\.py" "$0" | grep -E "(exec|python|nohup|setsid|kill|s6-setuidgid)[[:space:]]"' ../rootfs/usr/lib/halow/manager.sh
launcher="../rootfs/usr/lib/halow/status/launcher.sh"
if [ -f "$launcher" ]; then
    exec_line="$(grep -E '^[[:space:]]*exec[[:space:]]' "$launcher")"
    assert_eq "1" "$(grep -c . <<< "$exec_line")" "the launcher has exactly one exec"
    assert_success "that exec drops to the status user through s6-setuidgid" grep -qE '^[[:space:]]*exec s6-setuidgid "\$user" ' <<< "$exec_line"
    assert_success "the launcher's user defaults to HALOW_STATUS_USER / halowstatus" grep -qF 'user="${HALOW_STATUS_USER:-halowstatus}"' "$launcher"
    assert_success "the launcher drops the Supervisor token before exec" grep -qE 'unset SUPERVISOR_TOKEN' "$launcher"
else
    assert_file_exists "$launcher" "the status launcher exists"
fi
assert_success "the status service's run script uses the launcher" grep -q 'halow_status_launcher_main' ../rootfs/etc/services.d/status/run
server="../rootfs/usr/lib/halow/status/status_server.py"
assert_success "the status server refuses to run as root" grep -qE 'geteuid\(\) == 0' "$server"

echo "-- the container environment (Supervisor token) is restricted to root before any service --"
CI="../rootfs/etc/cont-init.d/00-restrict-container-environment"
assert_file_exists "$CI" "the cont-init hardening script exists"
assert_eq "1" "$(find ../rootfs/etc/cont-init.d -type f | grep -c .)" "it is the only cont-init script (s6 runs them all as root, in name order)"
assert_success "it parses" bash -n "$CI"
assert_success "its default is s6-overlay's container environment directory" grep -qF 'dir="${1:-/run/s6/container_environment}"' "$CI"
assert_failure "the directory cannot be redirected from the environment (only by an explicit argument)" grep -qE '\$\{?HALOW_[A-Z_]*ENV' "$CI"
ci_work="$(mktemp -d)"
_ci_env() { # _ci_env <dir> — a container_environment as s6-overlay leaves it (0755 / 0644)
    mkdir -p "$1"
    printf 'CANARY-not-a-real-token' > "$1/SUPERVISOR_TOKEN"
    printf 'CANARY-not-a-real-token' > "$1/HASSIO_TOKEN"
    printf '/usr/bin:/bin' > "$1/PATH"
    printf 'x' > "$1/.hidden"
    chmod 0755 "$1"; chmod 0644 "$1"/* "$1/.hidden"
}
_ci_env "$ci_work/env"
assert_success "the script succeeds on a container environment as s6-overlay leaves it" bash "$CI" "$ci_work/env"
assert_eq "700" "$(stat -c %a "$ci_work/env")" "the directory becomes 0700"
modes="$(cd "$ci_work/env" && stat -c '%a' SUPERVISOR_TOKEN HASSIO_TOKEN PATH .hidden | sort -u | tr '\n' ' ')"
assert_eq "600 " "$modes" "every file, including a dot file, becomes 0600"
assert_eq "CANARY-not-a-real-token" "$(cat "$ci_work/env/SUPERVISOR_TOKEN")" "the owner (root in the image) can still read the token (with-contenv keeps working)"
assert_success "running it again is harmless (idempotent)" bash "$CI" "$ci_work/env"
assert_failure "a missing directory fails closed (for example S6_KEEP_ENV: every process would hold the token)" bash "$CI" "$ci_work/absent"
ln -s "$ci_work/env" "$ci_work/link"
assert_failure "a directory given as a symbolic link fails closed" bash "$CI" "$ci_work/link"
_ci_env "$ci_work/env2"; mkdir "$ci_work/env2/subdir"
assert_failure "an entry that is not a plain file fails closed" bash "$CI" "$ci_work/env2"
_ci_env "$ci_work/env3"; ln -s /etc/hostname "$ci_work/env3/LINKED"
assert_failure "a symbolic link inside fails closed (chmod would follow it)" bash "$CI" "$ci_work/env3"
out="$(bash "$CI" "$ci_work/env" 2>&1)"
assert_failure "the script never prints a variable's value" grep -qF 'CANARY' <<< "$out"
# A stat that reports the old mode must make the verification fail (the check reads the
# file system, not the exit codes of chmod).
mkdir -p "$ci_work/fakebin"
real_stat="$(command -v stat)"
# A stat that misreports only the directory, then one that misreports only a token file.
printf '#!/bin/sh\ncase "$3" in */env4) echo "755 $(id -u)" ;; *) exec %s "$@" ;; esac\n' "$real_stat" > "$ci_work/fakebin/stat"; chmod +x "$ci_work/fakebin/stat"
_ci_env "$ci_work/env4"
assert_failure "the result is verified: a directory that does not read back as 0700 fails closed" env PATH="$ci_work/fakebin:$PATH" bash "$CI" "$ci_work/env4"
printf '#!/bin/sh\ncase "$3" in */SUPERVISOR_TOKEN) echo "644 $(id -u)" ;; *) exec %s "$@" ;; esac\n' "$real_stat" > "$ci_work/fakebin/stat"
_ci_env "$ci_work/env6"
assert_failure "the result is verified: a token file that does not read back as 0600 fails closed" env PATH="$ci_work/fakebin:$PATH" bash "$CI" "$ci_work/env6"
printf '#!/bin/sh\nexit 1\n' > "$ci_work/fakebin/chmod"; chmod +x "$ci_work/fakebin/chmod"; rm -f "$ci_work/fakebin/stat"
_ci_env "$ci_work/env5"
assert_failure "a chmod that fails stops the script" env PATH="$ci_work/fakebin:$PATH" bash "$CI" "$ci_work/env5"
rm -rf -- "$ci_work"

echo "-- udev is gone everywhere --"
assert_file_absent "../rootfs/usr/lib/halow/udev_rule.sh" "the udev rule library is deleted"
assert_file_absent "./test_udev_rule.sh" "its test is deleted"
assert_failure "config.yaml has no udev key" grep -qE '^[[:space:]]*udev[[:space:]]*:' ../config.yaml
assert_failure "the Dockerfile does not mention udev" grep -qi 'udev' "$DF"
assert_failure "build.sh does not mention udev" grep -qi 'udev' ../build.sh
assert_failure "the AppArmor profile grants nothing under /run/udev" grep -qE '^[[:space:]]*[^#]*/run/udev' ../apparmor.txt
udev_calls="$(grep -nE '(halow_[a-z_]*udev[a-z_]*|udev_rule\.sh|udevadm|/run/udev/rules\.d)' "${CODE_FILES[@]}" 2>/dev/null | grep -vE '^[^:]*:[0-9]+:[[:space:]]*#' | grep -v '/common\.sh:' || true)"
assert_eq "" "$udev_calls" "no code calls a udev function, udevadm or writes a udev rule (common.sh's unused path constant is a protected file and is not a use)"
assert_failure "the service directories no longer include the old single 'halow' service" test -d ../rootfs/etc/services.d/halow

echo "-- the manifest has no secret default --"
opt_block="$(awk '/^options:/ {p=1; next} /^[a-z_]+:/ {p=0} p' ../config.yaml)"
assert_failure "no default for the passphrase" grep -qE '^[[:space:]]+wifi_pass''phrase:' <<< "$opt_block"
assert_failure "no default whose name suggests a secret" grep -qiE '^[[:space:]]+[a-z_]*(pass|secret|token|psk|key)[a-z_]*:' <<< "$opt_block"
assert_success "the passphrase is a password-type option" grep -qE '^  wifi_pass''phrase: "password' ../config.yaml

echo "-- labels and runtime settings --"
assert_success "the title label is the product name, without a development-build or readiness qualifier" grep -qxF '    org.opencontainers.image.title="Morse Micro Wi-Fi HaLow Access Point for Home Assistant" \' "$DF"
assert_success "the description label ends with the region statement and carries no release-candidate or Experimental wording" bash -c 'grep -qE "description=\".*Region: Australia only\.\"$" "$0" && ! grep -E "^[[:space:]]*(io\.hass|org\.opencontainers)\.[a-z.]+=" "$0" | grep -qiE "release candidate|experimental"' "$DF"
assert_failure "no label says development build or not production-ready" bash -c 'grep -E "^[[:space:]]*(io\.hass|org\.opencontainers)\.[a-z.]+=" "$0" | grep -qiE "development build|not production-ready"' "$DF"
assert_success "the source label is the Morse Micro Labs repository address" grep -qF 'org.opencontainers.image.source="https://github.com/MorseMicroLabs/home-assistant-halow"' "$DF"
assert_failure "no OCI license label is set (the license record is LICENSE, NOTICE and THIRD-PARTY-NOTICES.md)" grep -qF 'org.opencontainers.image.licenses' "$DF"
assert_success "the Dockerfile copies the staged license, notice and source-record files to /usr/share/licenses/morse_micro_halow_ap in one layer" grep -qxF 'COPY legal-stage/ /usr/share/licenses/morse_micro_halow_ap/' "$DF"
assert_success "the ownership and mode normalization covers the license directory" bash -c 'n="$(grep -c "/usr/share/licenses/morse_micro_halow_ap" "$0")"; [ "$n" -ge 5 ]' "$DF"
assert_success "the Dockerfile has at most three COPY instructions (each adds a layer; the app's BusyBox mount fails on a long overlay line, so the license material arrives in one staged COPY)" bash -c '[ "$(grep -cE "^COPY[[:space:]]" "$0")" -le 3 ]' "$DF"
assert_success "the normalization sets the license parent directory to 0755" grep -qF 'chmod 0755 /etc /usr /usr/lib /usr/share /usr/share/licenses /opt' "$DF"
assert_success "labels name the target machine Home Assistant Green (aarch64)" grep -qE 'description=".*Home Assistant Green \(aarch64\)' "$DF"
assert_success "io.hass.arch is aarch64" grep -qF 'io.hass.arch="aarch64"' "$DF"
assert_success "io.hass.type is app (the label the current Home Assistant documentation shows)" grep -qF 'io.hass.type="app"' "$DF"
assert_success "the s6 grace times are set" grep -qE 'S6_SERVICES_GRACETIME=[0-9]+' "$DF"
assert_success "every service run/finish script is made executable" grep -qF 'find /etc/services.d -type f \( -name run -o -name finish \) -exec chmod 0755' <<< "$DF_JOINED"
norm="$(grep -F 'chmod 0755 /etc /usr /usr/lib /usr/share /usr/share/licenses /opt' <<< "$DF_JOINED")"
assert_success "modes are normalised after the last COPY (a world-writable build context must not reach the image)" test -n "$norm"
assert_success "the add-on files become 0644 and directories 0755" \
    bash -c 'grep -qF -- "-type d -exec chmod 0755" <<< "$0" && grep -qF -- "-type f -exec chmod 0644" <<< "$0"' "$norm"
assert_success "the add-on files are owned by root" grep -qF 'chown -R root:root /etc/services.d /etc/cont-init.d /usr/lib/halow /usr/share/halow /usr/share/licenses/morse_micro_halow_ap /opt/halow' <<< "$norm"
assert_success "the cont-init scripts are normalised and made executable" \
    bash -c 'grep -qF -- "find /etc/services.d /etc/cont-init.d /usr/lib/halow" <<< "$0" && grep -qF -- "find /etc/cont-init.d -type f -exec chmod 0755" <<< "$0"' "$norm"
last_copy="$(grep -nE '^COPY[[:space:]]' "$DF" | tail -n1 | cut -d: -f1)"
norm_line="$(grep -nF 'chmod 0755 /etc /usr /usr/lib /usr/share /usr/share/licenses /opt' "$DF" | cut -d: -f1)"
assert_success "the normalisation runs after every COPY" test "${norm_line:-0}" -gt "${last_copy:-999}"

echo "-- artifacts directory contract --"
assert_success "the artifacts and the manifest are copied from the staged directory in one layer (the manifest is a runtime dependency)" grep -qE '^COPY artifacts/ MANIFEST.sha256 /opt/halow/artifacts/$' <<< "$DF_CODE"
for exe in hostapd_s1g hostapd_cli_s1g; do
    assert_success "$exe is in MANIFEST.sha256 and made executable" bash -c 'grep -q "  ./$1\$" ../MANIFEST.sha256 && grep -q "/opt/halow/artifacts/$1" <<< "$2"' _ "$exe" "$DF_JOINED"
done
# The helper program that an earlier hostapd release line ran by bare name is not shipped.
assert_failure "MANIFEST.sha256 has no entry for the removed helper program" grep -qi 'morse_cli' ../MANIFEST.sha256
assert_failure "the Dockerfile does not mention the removed helper program (code or comments)" grep -qi 'morse_cli' "$DF"
assert_failure "build.sh does not stage the removed helper program" grep -qi 'morse_cli' ../build.sh
assert_failure "provenance.psv has no row for the removed helper program" grep -qi 'morse_cli' ../provenance.psv
assert_failure "corresponding_source.psv does not mention the removed helper program" grep -qi 'morse_cli' ../corresponding_source.psv
assert_failure "apparmor.txt does not mention the removed helper program" grep -qi 'morse_cli' ../apparmor.txt
assert_failure "the staged artifacts directory has no copy of the removed helper program" test -e ../artifacts/morse_cli
assert_success ".gitignore keeps the staged artifacts out of the repository" grep -qx 'artifacts/' ../.gitignore
assert_file_exists "../.dockerignore" ".dockerignore exists"
assert_success ".dockerignore excludes everything by default" grep -qx '\*' ../.dockerignore
for inc in Dockerfile MANIFEST.sha256 artifacts/ rootfs/ legal-stage/; do
    assert_success ".dockerignore lets $inc into the build" grep -qxF "!$inc" ../.dockerignore
done
for exc in tests docs README.md; do
    assert_failure ".dockerignore does not let $exc into the build" grep -qE "^!${exc}" ../.dockerignore
done
staged="$(awk '/^copy_verified "/ { gsub(/"/, "", $3); print "./" substr($3, length("artifacts/") + 1) }' ../build.sh | sort)"
manifest="$(awk '{print $2}' ../MANIFEST.sha256 | sort)"
assert_eq "$manifest" "$staged" "build.sh stages exactly the files of MANIFEST.sha256"

echo "-- build.sh, run against a throw-away copy and a dummy bundle --"
work="$(mktemp -d)"
mkdir -p "$work/addon" "$work/bundle/output/bcf"
cp ../build.sh ../Dockerfile ../config.yaml "$work/addon/"
for f in LICENSE NOTICE THIRD-PARTY-NOTICES.md SOURCE-OFFER.md PROVENANCE.md provenance.psv corresponding_source.psv source_disposition.psv; do cp "../$f" "$work/addon/"; done
cp -R ../LICENSES ../third-party-notices ../source-offer ../source-assets "$work/addon/"
while read -r _sha path; do
    printf 'dummy content of %s\n' "$path" > "$work/bundle/output/${path#./}"
done < ../MANIFEST.sha256
printf 'an extra bundle file that must not be staged\n' > "$work/bundle/output/extra.bin"
( cd "$work/bundle/output" && find . -type f | sort | xargs sha256sum ) > "$work/bundle/MANIFEST.sha256"
run_build() { ( cd "$work/addon" && env -u BUILD_IMAGE -u UPDATE_EXPECTED_MANIFEST "$@" bash ./build.sh ) > "$work/out.txt" 2>&1; }
assert_failure "build.sh refuses to run without ARTIFACT_BUNDLE_DIR" run_build env -u ARTIFACT_BUNDLE_DIR
assert_success "and says why" grep -q 'set ARTIFACT_BUNDLE_DIR' "$work/out.txt"
assert_failure "build.sh refuses a bundle without output/" run_build env ARTIFACT_BUNDLE_DIR="$work/nonexistent"
assert_failure "with no tracked manifest yet, build.sh refuses until one is accepted" run_build env ARTIFACT_BUNDLE_DIR="$work/bundle"
assert_success "UPDATE_EXPECTED_MANIFEST=1 accepts the staged set" run_build env ARTIFACT_BUNDLE_DIR="$work/bundle" UPDATE_EXPECTED_MANIFEST=1
assert_success "a second run matches the accepted manifest" run_build env ARTIFACT_BUNDLE_DIR="$work/bundle"
assert_success "build.sh prints the pinned base image" grep -qF "base image:        $from" "$work/out.txt"
assert_success "build.sh prints every pinned package" grep -qF "packages:          iproute2=6.17.0-r0 iptables=1.8.11-r1 nftables=1.1.5-r2 dnsmasq=2.91-r1 kmod=34.2-r1 dbus=1.16.2-r1 python3=3.12.16-r0" "$work/out.txt"
assert_success "build.sh prints the artifact manifest checksum" grep -qE '^artifact manifest: sha256 [0-9a-f]{64}$' "$work/out.txt"
assert_success "build.sh skips the image build unless asked" grep -q 'Skipping image build' "$work/out.txt"
assert_eq "$manifest" "$(cd "$work/addon/artifacts" && find . -type f | sort)" "exactly the manifest's files were staged (the extra bundle file was not)"
printf 'tampered\n' > "$work/bundle/output/morse.ko"
assert_failure "a bundle file that no longer matches the bundle manifest is refused" run_build env ARTIFACT_BUNDLE_DIR="$work/bundle"
printf 'dummy content of %s\n' ./morse.ko > "$work/bundle/output/morse.ko"
assert_success "restored bundle passes again" run_build env ARTIFACT_BUNDLE_DIR="$work/bundle"
sed -i 's/^    kmod=34.2-r1 \\$/    kmod \\/' "$work/addon/Dockerfile"
assert_success "test setup: the copy now has an unpinned package" grep -qE '^    kmod \\$' "$work/addon/Dockerfile"
assert_failure "build.sh refuses a Dockerfile with an unpinned package" run_build env ARTIFACT_BUNDLE_DIR="$work/bundle"
assert_success "and names it" grep -q "package 'kmod' in the Dockerfile is not pinned" "$work/out.txt"
cp ../Dockerfile "$work/addon/Dockerfile"
sed -i 's/^FROM .*/FROM ghcr.io\/home-assistant\/base:3.23/' "$work/addon/Dockerfile"
assert_failure "build.sh refuses a base image without a digest" run_build env ARTIFACT_BUNDLE_DIR="$work/bundle"
assert_success "and says so" grep -q 'not pinned by digest' "$work/out.txt"
rm -rf -- "$work"

echo "test_packaging: $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed"
exit $([ "$HALOW_TEST_FAILURES" -eq 0 ] && echo 0 || echo 1)
