#!/usr/bin/env bash
# Tests guard.sh (halow_guard_check, halow_guard_report) against a fake kernel built by
# hat_guard_world (helpers_adapter.sh): a module tree with small real files whose SHA-256 values
# the test manifest records, a fake /proc/version and /proc/config.gz, a fake /sys/module, the
# bundled driver modules, and fake `modinfo` and `uname`. Also checks the shipped manifest
# against the official values and that the guard only ever runs read-only commands.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh
. ./helpers_adapter.sh

echo "== test_guard =="
hat_setup
GW="$HAT_TMP/gw"
REAL_PATH="$PATH"

reset_world() {
    rm -rf "$GW" "$HALOW_ARTIFACTS_DIR" "$HALOW_SYS_MODULE_DIR"
    mkdir -p "$HALOW_ARTIFACTS_DIR" "$HALOW_SYS_MODULE_DIR"
    unset HALOW_UNAME_RELEASE HALOW_UNAME_VERSION HAT_GW_RELEASE HAT_GW_BUILD_SEEN HAT_GW_UNAME_FAIL
    hat_guard_world "$GW"
    PATH="$HAT_GW_BIN:$REAL_PATH"
    : > "$HAT_CALLS"
}
reason_has() { # <substring> <msg>
    HALOW_TEST_COUNT=$((HALOW_TEST_COUNT + 1))
    case "${HALOW_GUARD_REASON:-}" in
        *"$1"*) echo "  ok: $2" ;;
        *) echo "  FAIL: $2 (reason was '${HALOW_GUARD_REASON:-}')"; HALOW_TEST_FAILURES=$((HALOW_TEST_FAILURES + 1)) ;;
    esac
}
modpath() { # <module>: the fake host file of a module
    case "$1" in
        cfg80211) printf '%s' "$HAT_GW_TREE/kernel/net/wireless/cfg80211.ko" ;;
        mac80211) printf '%s' "$HAT_GW_TREE/kernel/net/mac80211/mac80211.ko" ;;
        libarc4)  printf '%s' "$HAT_GW_TREE/kernel/lib/crypto/libarc4.ko" ;;
    esac
}
# set_row <module> <relative path> <sha256>: rewrites that module's host_module row.
set_row() {
    local bidvar="HAT_GW_BID_$1"
    grep -v "^host_module|$HAT_GW_REL|$1|" "$HALOW_GUARD_MANIFEST" > "$HAT_TMP/m.tmp"
    printf 'host_module|%s|%s|%s|%s|%s\n' "$HAT_GW_REL" "$1" "$2" "$3" "${!bidvar}" >> "$HAT_TMP/m.tmp"
    mv "$HAT_TMP/m.tmp" "$HALOW_GUARD_MANIFEST"
}
sha_of() { local s; s="$(sha256sum "$1")"; printf '%s' "${s%% *}"; }
loaded() { # <module> <taint> [<build-id>]
    mkdir -p "$HALOW_SYS_MODULE_DIR/$1"
    printf '%s\n' "$2" > "$HALOW_SYS_MODULE_DIR/$1/taint"
    if [ -n "${3:-}" ]; then hat_gw_note "$HALOW_SYS_MODULE_DIR/$1/notes/.note.gnu.build-id" "$3"; fi
}

echo "-- supported tuple --"
reset_world
assert_exit 0 "release, build string, banner, configuration and the exact module files pass" halow_guard_check
assert_eq "" "$HALOW_GUARD_REASON" "no reason is set on success"
assert_success "uname -r was consulted" grep -qx 'uname -r' "$HAT_CALLS"
assert_success "uname -v was consulted" grep -qx 'uname -v' "$HAT_CALLS"
assert_success "the loader's file was resolved with modinfo -b/-k/-F filename" grep -q "^modinfo -b $GW/base -k 6.18.58-haos -F filename cfg80211$" "$HAT_CALLS"
reset_world
export HALOW_UNAME_RELEASE="$HAT_GW_REL" HALOW_UNAME_VERSION="$HAT_GW_BUILD"
export HAT_GW_RELEASE="9.9.9" HAT_GW_BUILD_SEEN="#9"
assert_exit 0 "HALOW_UNAME_RELEASE and HALOW_UNAME_VERSION override uname" halow_guard_check
assert_failure "uname is not called when both overrides are set" grep -q '^uname' "$HAT_CALLS"

echo "-- release, build string, banner, configuration --"
reset_world; export HAT_GW_RELEASE="6.18.53-haos"
assert_exit 1 "an unknown release is unsupported" halow_guard_check
reason_has "6.18.53-haos is not supported" "the reason names the release"
reset_world; export HAT_GW_RELEASE="6.18.52-haos"
assert_exit 1 "the previous release (Home Assistant OS 18.3, kernel 6.18.52-haos) is refused: the bundled modules are built for 6.18.58" halow_guard_check
reason_has "6.18.52-haos is not supported" "the reason names the previous release"
reason_has "supported: 6.18.58-haos" "the reason names the only supported release"
reset_world; export HAT_GW_UNAME_FAIL=r
assert_exit 2 "an unreadable release is undeterminable" halow_guard_check
reset_world; export HAT_GW_BUILD_SEEN="#1 SMP PREEMPT Fri Sep 18 09:00:00 UTC 2026"
assert_exit 1 "the same release with a different build string is unsupported" halow_guard_check
reason_has "build string" "the reason names the build string"
reset_world; export HAT_GW_UNAME_FAIL=v
assert_exit 2 "an unreadable build string is undeterminable" halow_guard_check
reset_world; printf 'Linux version 6.18.58-haos (other@host) %s\n' "$HAT_GW_BUILD" > "$HALOW_PROC_VERSION"
assert_exit 1 "a different kernel banner is unsupported" halow_guard_check
reason_has "banner does not match" "the reason names the banner"
reset_world; rm -f "$HALOW_PROC_VERSION"
assert_exit 2 "an unreadable banner is undeterminable" halow_guard_check
reset_world; printf 'CONFIG_TEST=m\n' | gzip -c > "$HALOW_PROC_CONFIG_GZ"
assert_exit 1 "a different embedded configuration is unsupported" halow_guard_check
reason_has "configuration SHA-256" "the reason names the configuration"
reset_world; rm -f "$HALOW_PROC_CONFIG_GZ"
assert_exit 2 "a missing /proc/config.gz is undeterminable" halow_guard_check
reset_world; printf 'not gzip\n' > "$HALOW_PROC_CONFIG_GZ"
assert_exit 2 "an undecompressable /proc/config.gz is undeterminable" halow_guard_check
reset_world; chmod 000 "$HALOW_PROC_CONFIG_GZ"
if [ -r "$HALOW_PROC_CONFIG_GZ" ]; then
    echo "  skip: running with privileges that ignore file modes; unreadable configuration not testable"
else
    assert_exit 2 "an unreadable /proc/config.gz is undeterminable" halow_guard_check
fi
chmod 644 "$HALOW_PROC_CONFIG_GZ"

echo "-- exact module files: everything else matching, one byte different --"
for m in cfg80211 mac80211 libarc4; do
    reset_world
    f="$(modpath "$m")"
    before="$(sha_of "$f")"
    sed -i 's/official/officiaL/' "$f"
    assert_failure "(the $m file really changed)" test "$before" = "$(sha_of "$f")"
    assert_exit 1 "one byte different in $m (release, build, banner, config, vermagic matching) is unsupported" halow_guard_check
    reason_has "host module $m SHA-256" "the reason names $m's hash"
done

echo "-- the file the loader would use, and a single copy --"
reset_world; mkdir -p "$HAT_GW_TREE/updates"; cp "$(modpath mac80211)" "$HAT_GW_TREE/updates/mac80211.ko"
assert_exit 1 "an identical copy in updates/ that the loader prefers is unsupported" halow_guard_check
reason_has "resolves to" "the reason names the resolved path"
reset_world; mkdir -p "$HAT_GW_TREE/misc"; cp "$(modpath cfg80211)" "$HAT_GW_TREE/misc/cfg80211.ko"
assert_exit 1 "a second copy elsewhere in the tree is unsupported" halow_guard_check
reason_has "exists 2 times" "the reason counts the copies"
reset_world; mkdir -p "$HAT_GW_TREE/extra"; cp "$(modpath libarc4)" "$HAT_GW_TREE/extra/libarc4-alt.ko"
printf 'libarc4 extra/libarc4-alt.ko\n' > "$HAT_GW_TREE/fake.resolve"
assert_exit 1 "the loader resolving to a differently named file is unsupported" halow_guard_check
reason_has "libarc4 resolves to" "the reason names libarc4"
reset_world; rm -f "$(modpath libarc4)"
assert_exit 2 "a missing module is a refusal (undeterminable)" halow_guard_check
reset_world; rm -f "$(modpath libarc4)"; printf 'libarc4 kernel/lib/crypto/libarc4.ko\n' > "$HAT_GW_TREE/fake.resolve"
assert_exit 2 "a missing module the loader index still names is a refusal (undeterminable)" halow_guard_check
reason_has "libarc4 not found" "the reason says the file is missing"
reset_world; chmod 000 "$(modpath mac80211)"
if [ -r "$(modpath mac80211)" ]; then
    echo "  skip: running with privileges that ignore file modes; unreadable module not testable"
else
    assert_exit 2 "an unreadable module is a refusal (undeterminable)" halow_guard_check
    reason_has "could not be read" "the reason says unreadable"
fi
chmod 644 "$(modpath mac80211)" 2>/dev/null
reset_world; f="$(modpath cfg80211)"; cp "$f" "$HAT_TMP/cfg-copy.ko"; rm -f "$f"; ln -s "$HAT_TMP/cfg-copy.ko" "$f"
assert_exit 1 "the supported path being a symbolic link (even to identical bytes) is unsupported" halow_guard_check
reason_has "symbolic link" "the reason says symbolic link"
reset_world; f="$(modpath cfg80211)"; rm -f "$f"; mkdir -p "$HAT_GW_TREE/other"; printf 'vermagic=%s\n' "$HAT_GW_VM" > "$HAT_GW_TREE/other/x.ko"; ln -s ../../../other/x.ko "$f"
assert_exit 1 "a symbolic link to a different file is unsupported" halow_guard_check
reset_world; f="$(modpath cfg80211)"; xz -c "$f" > "$f.xz"; rm -f "$f"
assert_exit 1 "the wrong compression form (.ko.xz present, manifest says .ko) is unsupported" halow_guard_check
reset_world; f="$(modpath cfg80211)"; rm -f "$f"; mkdir -p "$f"
assert_exit 1 "a directory at the supported path is unsupported" halow_guard_check

echo "-- vermagic of the host module (defence in depth) --"
reset_world; f="$(modpath libarc4)"; sed -i 's/^vermagic=.*/vermagic=6.18.58-haos SMP mod_unload aarch64/' "$f"; set_row libarc4 kernel/lib/crypto/libarc4.ko "$(sha_of "$f")"
assert_exit 1 "a recorded file with another vermagic is unsupported" halow_guard_check
reason_has "vermagic" "the reason names the vermagic"
reset_world; f="$(modpath libarc4)"; printf 'UNREADABLE\n' > "$f"; set_row libarc4 kernel/lib/crypto/libarc4.ko "$(sha_of "$f")"
assert_exit 2 "a recorded file whose metadata cannot be read is undeterminable" halow_guard_check

echo "-- compressed rows (how a future release would be added; hash of the file as stored) --"
for ext in xz gz; do
    reset_world; f="$(modpath mac80211)"
    if [ "$ext" = xz ]; then xz -c "$f" > "$f.xz"; else gzip -c "$f" > "$f.gz"; fi
    rm -f "$f"
    set_row mac80211 "kernel/net/mac80211/mac80211.ko.$ext" "$(sha_of "$f.$ext")"
    assert_exit 0 "a .ko.$ext row with the matching stored file passes" halow_guard_check
    printf 'x' >> "$f.$ext"
    assert_exit 1 "a .ko.$ext row with a different stored file is unsupported" halow_guard_check
done
reset_world; f="$(modpath mac80211)"; cp "$f" "$f.zst"; rm -f "$f"
set_row mac80211 kernel/net/mac80211/mac80211.ko.zst "$(sha_of "$f.zst")"
assert_exit 2 "a .zst row whose stored hash matches is still refused: its metadata cannot be read" halow_guard_check
reason_has "zstd" "the reason names the zstd form"
printf 'x' >> "$f.zst"
assert_exit 1 "a .zst row with different stored bytes is unsupported" halow_guard_check

echo "-- already loaded modules --"
reset_world; loaded cfg80211 "" "$HAT_GW_BID_cfg80211"
assert_exit 0 "a loaded, untainted module with the recorded build-id passes" halow_guard_check
reset_world; loaded mac80211 "E" "$HAT_GW_BID_mac80211"
assert_exit 1 "a loaded module with taint E is unsupported" halow_guard_check
reason_has "tainted (E)" "the reason names the taint"
for t in O P C F OE; do
    reset_world; loaded libarc4 "$t"
    assert_exit 1 "a loaded module with taint $t is unsupported" halow_guard_check
done
reset_world; loaded cfg80211 "" "0000000000000000000000000000000000000000"
assert_exit 1 "a loaded module with another build-id is unsupported" halow_guard_check
reason_has "build-id" "the reason names the build-id"
reset_world; loaded cfg80211 ""
assert_exit 0 "an unreadable build-id note is recorded and does not refuse" halow_guard_check
assert_success "...and the report says so" grep -qx 'loaded_cfg80211_build_id=unreadable' <<< "$(halow_guard_report)"
reset_world; mkdir -p "$HALOW_SYS_MODULE_DIR/mac80211"
assert_exit 2 "a loaded module without a readable taint is undeterminable" halow_guard_check
reset_world; loaded libarc4 ""; mkdir -p "$HALOW_SYS_MODULE_DIR/libarc4/notes"; printf 'junk' > "$HALOW_SYS_MODULE_DIR/libarc4/notes/.note.gnu.build-id"
assert_exit 2 "a malformed build-id note is undeterminable" halow_guard_check

echo "-- the loaded-module directory itself: not readable means undeterminable, never 'not loaded' --"
reset_world; rm -rf "$HALOW_SYS_MODULE_DIR"
assert_exit 2 "a missing loaded-module directory is undeterminable" halow_guard_check
reason_has "loaded-module directory" "the reason names the loaded-module directory"
reset_world; rm -rf "$HALOW_SYS_MODULE_DIR"/*
assert_exit 2 "an empty loaded-module directory is undeterminable" halow_guard_check
reset_world; chmod 000 "$HALOW_SYS_MODULE_DIR"
if [ -r "$HALOW_SYS_MODULE_DIR" ]; then
    echo "  skip: running with privileges that ignore file modes; unreadable directory not testable"
else
    assert_exit 2 "an unreadable loaded-module directory is undeterminable" halow_guard_check
fi
chmod 755 "$HALOW_SYS_MODULE_DIR"
reset_world
assert_exit 0 "a readable directory listing other modules, without the three, means not loaded" halow_guard_check

echo "-- a copy behind a symbolic link to a directory counts --"
reset_world; mkdir -p "$HAT_TMP/elsewhere"; cp "$(modpath mac80211)" "$HAT_TMP/elsewhere/mac80211.ko"; ln -s "$HAT_TMP/elsewhere" "$HAT_GW_TREE/updates"
assert_eq "$HAT_GW_TREE/kernel/net/mac80211/mac80211.ko" "$(_halow_guard_resolve "$HAT_GW_REL" mac80211)" "(the fake loader index does not see the linked copy, so only the single-copy check can)"
assert_exit 1 "an extra copy in a symlinked updates directory is unsupported" halow_guard_check
reason_has "exists 2 times" "the reason counts the linked copy"

echo "-- test overrides are honoured only in test mode --"
reset_world
export HALOW_UNAME_RELEASE="0.0.0-bogus"
assert_exit 1 "in test mode a release override is honoured (control)" halow_guard_check
unset HALOW_GUARD_TEST_MODE
report="$(halow_guard_report)"
assert_success "without test mode the release override is ignored (uname is used)" grep -qx "kernel_release=$HAT_GW_REL" <<< "$report"
assert_success "without test mode the shipped manifest path is used" grep -qx "guard_manifest=/usr/share/halow/guard_manifest.psv" <<< "$report"
assert_success "the report says overrides are off" grep -qx "guard_test_overrides=no" <<< "$report"
assert_eq "/sys/module" "$(_halow_guard_sys_module_dir)" "without test mode the loaded-module directory is /sys/module"
assert_eq "/proc/version|/proc/config.gz|/" "$(_halow_guard_proc_version)|$(_halow_guard_proc_config)|$(_halow_guard_modules_base)" "without test mode the proc files and module base are the production ones"
if [ ! -e /usr/share/halow/guard_manifest.psv ]; then
    assert_exit 2 "without test mode (no shipped manifest on this machine) the guard refuses" halow_guard_check
    reason_has "/usr/share/halow/guard_manifest.psv" "the reason names the production manifest, not the override"
fi
export HALOW_GUARD_TEST_MODE=0
assert_eq "/sys/module" "$(_halow_guard_sys_module_dir)" "a test-mode value other than 1 is not test mode"
export HALOW_GUARD_TEST_MODE=1
unset HALOW_UNAME_RELEASE

echo "-- bundled driver modules --"
reset_world; printf 'srcversion=33333333333333333333333\nvermagic=6.18.58-haos SMP preempt mod_unload x86_64\n' > "$HALOW_ARTIFACTS_DIR/morse.ko"
assert_exit 1 "a bundled module with another vermagic is refused" halow_guard_check
reset_world; printf 'srcversion=FFFFFFFFFFFFFFFFFFFFFFF\nvermagic=%s\n' "$HAT_GW_VM" > "$HALOW_ARTIFACTS_DIR/dot11ah.ko"
assert_exit 1 "a bundled module with another source hash is refused" halow_guard_check
reset_world; rm -f "$HALOW_ARTIFACTS_DIR/morse.ko"
assert_exit 2 "a missing bundled module is a refusal" halow_guard_check

echo "-- manifest missing or malformed: fail closed --"
reset_world; rm -f "$HALOW_GUARD_MANIFEST"
assert_exit 2 "a missing manifest is refused" halow_guard_check
reset_world; GOOD="$(cat "$HALOW_GUARD_MANIFEST")"
CFG_ROW="$(grep '^host_module|[^|]*|cfg80211|' <<< "$GOOD")"
malformed() { # <description> <content>
    reset_world
    printf '%s\n' "$2" > "$HALOW_GUARD_MANIFEST"
    assert_exit 2 "malformed manifest ($1) is refused" halow_guard_check
}
malformed "empty file" ""
malformed "comments only" "# nothing"
malformed "short host row" "$(sed 's/^\(host_module|[^|]*|cfg80211|[^|]*|[^|]*\)|.*/\1/' <<< "$GOOD")"
malformed "long host row" "$(sed 's/^\(host_module|[^|]*|cfg80211|.*\)$/\1|extra/' <<< "$GOOD")"
malformed "non-hex hash" "$(sed 's/^\(host_module|[^|]*|cfg80211|[^|]*\)|[0-9a-f]*|/\1|zz42ad673f449b8dc9932f2c8c00c838b62aeef99fcdc4f84ccb98f8a447656|/' <<< "$GOOD")"
malformed "upper-case hash" "$(sed 's/^\(host_module|[^|]*|cfg80211|[^|]*\)|\([0-9a-f]*\)|/\1|\U\2|/' <<< "$GOOD")"
malformed "hash of the wrong length" "$(sed 's/^\(host_module|[^|]*|cfg80211|[^|]*\)|\([0-9a-f]*\)|/\1|\2ab|/' <<< "$GOOD")"
malformed "build-id of the wrong length" "$(sed 's/^\(host_module|[^|]*|cfg80211|.*\)|\([0-9a-f]*\)$/\1|\2ff/' <<< "$GOOD")"
malformed "duplicate module" "${GOOD}
${CFG_ROW}"
malformed "a module missing" "$(grep -v '|libarc4|' <<< "$GOOD")"
malformed "path outside the tree" "$(sed 's#|kernel/net/wireless/cfg80211.ko|#|../wireless/cfg80211.ko|#' <<< "$GOOD")"
malformed "absolute path" "$(sed 's#|kernel/net/wireless/cfg80211.ko|#|/kernel/net/wireless/cfg80211.ko|#' <<< "$GOOD")"
malformed "path naming another module" "$(sed 's#|kernel/net/wireless/cfg80211.ko|#|kernel/net/wireless/mac80211.ko|#' <<< "$GOOD")"
malformed "unknown host module" "${GOOD}
host_module|$HAT_GW_REL|ath9k|kernel/ath9k.ko|$(printf '%064d' 0)|$(printf '%040d' 0)"
malformed "unknown row type" "${GOOD}
kernel|$HAT_GW_REL|x"
malformed "missing banner row" "$(grep -v '^kernel_banner' <<< "$GOOD")"
malformed "missing config row" "$(grep -v '^kernel_config' <<< "$GOOD")"
malformed "bad config hash" "$(sed 's/^kernel_config|\([^|]*\)|.*/kernel_config|\1|abc/' <<< "$GOOD")"
malformed "missing build row" "$(grep -v '^kernel_build' <<< "$GOOD")"
malformed "rows for a release without a release row" "${GOOD}
${CFG_ROW/6.18.58-haos/7.0.0}"
malformed "a second release without its own rows" "${GOOD}
release|7.0.0|vermagic|7.0.0 SMP"
reset_world; printf '%s\n' "$GOOD" | sed 's/$/\r/' > "$HALOW_GUARD_MANIFEST"
assert_exit 0 "a manifest with CRLF line endings is read exactly" halow_guard_check

echo "-- diagnostics report --"
reset_world
export HALOW_CFG_WIFI_PASSPHRASE="correct-horse-battery-staple"
loaded mac80211 "" "$HAT_GW_BID_mac80211"
report="$(halow_guard_report)"; rc=$?
assert_eq 0 "$rc" "the report returns 0"
for kv in "guard_result=0" "kernel_release=$HAT_GW_REL" "kernel_build=$HAT_GW_BUILD" "kernel_banner_match=yes" \
          "kernel_config_match=yes" "host_cfg80211_path=$HAT_GW_TREE/kernel/net/wireless/cfg80211.ko" \
          "host_libarc4_copies=1" "host_mac80211_sha256=$(sha_of "$(modpath mac80211)")" \
          "expected_mac80211_sha256=$(sha_of "$(modpath mac80211)")" "loaded_mac80211=yes" "loaded_mac80211_taint=none" \
          "loaded_mac80211_build_id=match" "loaded_cfg80211=no"; do
    assert_success "report: $kv" grep -qxF "$kv" <<< "$report"
done
assert_eq 0 "$(grep -cvE '^[a-z0-9_]+=' <<< "$report")" "every report line is key=value"
assert_failure "the report contains no passphrase" grep -q "correct-horse" <<< "$report"
unset HALOW_CFG_WIFI_PASSPHRASE
reset_world; sed -i 's/official/officiaL/' "$(modpath cfg80211)"
report="$(halow_guard_report)"
assert_success "report on refusal: result 1 and a one-line reason" grep -q '^guard_reason=host module cfg80211 SHA-256' <<< "$report"
reset_world; rm -f "$HALOW_GUARD_MANIFEST"
report="$(halow_guard_report)"; rc=$?
assert_eq 0 "$rc" "the report returns 0 without a manifest"
assert_success "report: manifest invalid" grep -qx 'guard_manifest_state=invalid' <<< "$report"

echo "-- the shipped manifest --"
SHIPPED="$HAT_SHARE_DIR/guard_manifest.psv"
assert_success "the shipped manifest is complete and every row well formed" _halow_guard_load_manifest "$SHIPPED"
assert_eq "6.18.58-haos" "$_HALOW_GUARD_RELEASES" "exactly one supported release (18.3 rows removed: the bundled modules are built for 6.18.58 only)"
R="6.18.58-haos"
assert_eq "6.18.58-haos SMP preempt mod_unload aarch64" "${_HALOW_GUARD_VERMAGIC[$R]}" "shipped vermagic"
assert_eq "#1 SMP PREEMPT Tue Oct 27 13:46:33 UTC 2026" "${_HALOW_GUARD_BUILD[$R]}" "shipped build string"
assert_eq "Linux version 6.18.58-haos (builder@4772b50a3096) (aarch64-buildroot-linux-gnu-gcc.br_real (Buildroot -g30c038aa) 13.4.0, GNU ld (GNU Binutils) 2.43.1) #1 SMP PREEMPT Tue Oct 27 13:46:33 UTC 2026" "${_HALOW_GUARD_BANNER[$R]}" "shipped banner"
assert_eq "a4426c779010b70d480504acc70948c3363960d2d0a5fe1fba1c32cd3b1aac4c" "${_HALOW_GUARD_CONFIG[$R]}" "shipped configuration hash"
assert_eq "kernel/net/wireless/cfg80211.ko|0088a887c9d7769ca78abbd75a782689a18722bc3b893e7cdf5439d119a1d6d0|834e2f76f0eac52d7b86865b3395d8b80de77a1d" \
    "${_HALOW_GUARD_HPATH[$R|cfg80211]}|${_HALOW_GUARD_HSHA[$R|cfg80211]}|${_HALOW_GUARD_HBID[$R|cfg80211]}" "shipped cfg80211 path, hash and build-id are the official ones"
assert_eq "kernel/net/mac80211/mac80211.ko|16102dc27141a53f4195f088a229b028100f9a462be04aa437161049ef108491|488f6476e6cc4b0e6923e1cbbe73d98062c583f4" \
    "${_HALOW_GUARD_HPATH[$R|mac80211]}|${_HALOW_GUARD_HSHA[$R|mac80211]}|${_HALOW_GUARD_HBID[$R|mac80211]}" "shipped mac80211 path, hash and build-id are the official ones"
assert_eq "kernel/lib/crypto/libarc4.ko|55fc535dc37531f422ab8b24d5aad4e774462456a4acafd9659228893cc53443|5442ed198511acfe5f406a44bbdce6056c32cb29" \
    "${_HALOW_GUARD_HPATH[$R|libarc4]}|${_HALOW_GUARD_HSHA[$R|libarc4]}|${_HALOW_GUARD_HBID[$R|libarc4]}" "shipped libarc4 path, hash and build-id are the official ones"
assert_eq "C601E85123B2E7F4B6A44FE 3B02991D4DB75E404FAEB63" "${_HALOW_GUARD_ART[$R|morse.ko]} ${_HALOW_GUARD_ART[$R|dot11ah.ko]}" "shipped bundled-module source hashes"
assert_eq "6" "$(grep -c -E '^(release|kernel_build|kernel_banner|kernel_config|artifact)\|' "$SHIPPED")" "shipped kernel and artifact rows"
assert_eq "3" "$(grep -c '^host_module|' "$SHIPPED")" "exactly three shipped host_module rows"
assert_success "the shipped header says the values are unverified on a device" grep -q 'unverified' "$SHIPPED"
assert_success "the shipped header names the two official 18.4 artifacts" grep -q 'b5d9a4869a9c70a9d87946f8ba90c72b0a42b393404fa8bf82e161452b8c6aba' "$SHIPPED"
assert_success "...and the bundle" grep -q '8e7189352061686fb9c54bacdd6fe8fa700a50ec5af5630df1cf0af39ff25a3f' "$SHIPPED"
assert_eq "0" "$(grep -v '^#' "$SHIPPED" | grep -c '6\.18\.52')" "no 6.18.52 row remains in the shipped manifest"
assert_success "the shipped header says why only one release is listed" grep -q 'Why exactly one release is listed' "$SHIPPED"
for w in "reproduced" "reuses the same build string" "substitution"; do
    assert_failure "superseded wording '$w' is gone from the guard files" grep -q -i "$w" "$SHIPPED" "$HAT_LIB_DIR/guard.sh"
done
REAL_ART="$(cd .. && pwd)/artifacts"
REAL_MODINFO="$(PATH="$REAL_PATH" command -v modinfo || true)"
if [ -z "$REAL_MODINFO" ] && [ -x /usr/sbin/modinfo ]; then REAL_MODINFO=/usr/sbin/modinfo; fi
if [ -n "$REAL_MODINFO" ] && [ -f "$REAL_ART/morse.ko" ] && [ -f "$REAL_ART/dot11ah.ko" ]; then
    for a in morse.ko dot11ah.ko; do
        assert_eq "${_HALOW_GUARD_ART[$R|$a]}" "$("$REAL_MODINFO" -F srcversion "$REAL_ART/$a")" "shipped srcversion of $a matches the bundled file"
        assert_eq "${_HALOW_GUARD_VERMAGIC[$R]}" "$("$REAL_MODINFO" -F vermagic "$REAL_ART/$a")" "bundled $a carries the shipped vermagic"
    done
else
    echo "  skip: real modinfo or bundled modules not available; shipped artifact rows not compared"
fi

echo "-- no mutation: only read-only commands run --"
RBIN="$HAT_TMP/rbin"
reset_world
mkdir -p "$RBIN"; cp "$HAT_GW_BIN/modinfo" "$HAT_GW_BIN/uname" "$RBIN/"
hat_recording_bin "$RBIN" find sha256sum zcat gzip od
restricted() { local PATH="$RBIN"; "$@"; }
loaded libarc4 "" "$HAT_GW_BID_libarc4"
before="$(hat_tree_listing "$GW"; hat_tree_listing "$HALOW_ARTIFACTS_DIR"; hat_tree_listing "$HALOW_SYS_MODULE_DIR")"
: > "$HAT_CALLS"
assert_exit 0 "the guard passes with only the recording command directory on PATH" restricted halow_guard_check
restricted halow_guard_report >/dev/null
after="$(hat_tree_listing "$GW"; hat_tree_listing "$HALOW_ARTIFACTS_DIR"; hat_tree_listing "$HALOW_SYS_MODULE_DIR")"
assert_eq "$before" "$after" "module tree, proc files, manifest, artifacts and sysfs are unchanged"
sed -i 's/official/officiaL/' "$(modpath mac80211)"
assert_exit 1 "a refusal path under the recording PATH" restricted halow_guard_check
called="$(hat_called_commands)"
extra="$called"
for c in modinfo uname find sha256sum zcat gzip od; do extra="${extra// $c / }"; done
assert_eq " " "$extra" "only modinfo, uname, find, sha256sum, zcat (and its gzip) and od ran (called:$called)"
for c in modinfo uname find sha256sum zcat od; do
    assert_success "$c was used" grep -q "^$c " "$HAT_CALLS"
done
assert_failure "no state-changing or unexpected command was attempted" grep -q '^MUTATE' "$HAT_CALLS"

echo "-- strict shell mode --"
STRICT="$HAT_TMP/strict.sh"
cat > "$STRICT" <<EOF
set -o errexit -o errtrace -o nounset -o pipefail
shopt -s inherit_errexit
. "$HAT_LIB_DIR/constants.sh"; . "$HAT_LIB_DIR/common.sh"; . "$HAT_LIB_DIR/guard.sh"
f() { if halow_guard_check 2>/dev/null; then echo "rc=0"; else echo "rc=\$?"; fi; halow_guard_report >/dev/null; echo done; }
f
EOF
reset_world
assert_eq "rc=0
done" "$(bash "$STRICT")" "check and report under errexit/nounset/pipefail (supported)"
sed -i 's/official/officiaL/' "$(modpath libarc4)"
assert_eq "rc=1
done" "$(bash "$STRICT")" "check and report under errexit/nounset/pipefail (different module file)"
rm -f "$HALOW_GUARD_MANIFEST"
assert_eq "rc=2
done" "$(bash "$STRICT")" "check and report under errexit/nounset/pipefail (no manifest)"
assert_success "guard.sh can be sourced twice" bash -c ". '$HAT_LIB_DIR/guard.sh'; . '$HAT_LIB_DIR/guard.sh'; declare -F halow_guard_check"

hat_teardown
echo "test_guard: $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed"
exit $([ "$HALOW_TEST_FAILURES" -eq 0 ] && echo 0 || echo 1)
