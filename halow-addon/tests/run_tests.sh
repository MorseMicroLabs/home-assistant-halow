#!/usr/bin/env bash
# off-device test runner. Most suites need neither Docker nor hardware.
# The real-tool suites (test_ipv6_real_container.sh, test_firewall_real_nft.sh) run the real
# tools in a throw-away Docker container with no host network; when Docker or a usable image
# is missing they print "SKIPPED: <reason>" and exit 77. A skip is NOT a pass: it is counted
# and listed in the summary, and with HALOW_REQUIRE_REAL=1 any skipped suite fails the run.
# Every other test redirects all path constants to a disposable temp directory (see
# test_helpers.sh's halow_test_setup) — nothing here touches the real host filesystem.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
REPO_ROOT="$(cd .. && pwd)"

echo "== syntax check (bash -n) =="
syntax_fail=0
checked=0
for f in "$REPO_ROOT"/rootfs/usr/lib/halow/*.sh \
         "$REPO_ROOT"/rootfs/usr/lib/halow/status/* \
         "$REPO_ROOT"/rootfs/etc/services.d/*/* \
         "$REPO_ROOT"/rootfs/etc/cont-init.d/* \
         "$REPO_ROOT"/tools/*.sh \
         "$REPO_ROOT"/build.sh \
         ./test_*.sh ./helpers_*.sh ./doubles/*.sh ./doubles/bin/* ./fakes/* ./image_*.sh ./reconcile_*.sh ./verify_image.sh ./run_tests.sh; do
    [ -f "$f" ] || continue
    # Only shell scripts: Python files and data files (for example the s6 finish time
    # limit, a bare number) are skipped by their first line or name.
    case "$f" in *.py|*.pyc|*.html|*.css|*.json|*.md) continue ;; esac
    case "$(head -c 64 "$f" 2>/dev/null)" in
        '#!'*python*) continue ;;
        '#!'*sh*|'#!'*bashio*) : ;;
        *) case "$f" in *.sh) : ;; *) continue ;; esac ;;
    esac
    checked=$((checked + 1))
    if bash -n "$f" 2>&1; then
        echo "  OK: $f"
    else
        echo "  SYNTAX ERROR: $f"
        syntax_fail=1
    fi
done
echo "  ($checked shell files checked)"
if [ "$syntax_fail" -ne 0 ]; then
    echo "Syntax check failed; not running tests."
    exit 1
fi
echo

TOTAL_FAILED_SUITES=0
TOTAL_SKIPPED_SUITES=0
TOTAL_SUITES=0
FAILED_LIST=""
SKIPPED_LIST=""
SKIP_RC=77
RCFILE="$(mktemp)"
trap 'rm -f "$RCFILE"' EXIT

for t in test_*.sh; do
    [ "$t" = "test_helpers.sh" ] && continue
    TOTAL_SUITES=$((TOTAL_SUITES + 1))
    echo "---- $t ----"
    # The suite's own exit status is kept through the pipe in $RCFILE.
    { bash "$t" 2>&1; echo "$?" > "$RCFILE"; } | cat
    trc="$(cat "$RCFILE")"
    if [ "$trc" -eq 0 ]; then
        :
    elif [ "$trc" -eq "$SKIP_RC" ]; then
        TOTAL_SKIPPED_SUITES=$((TOTAL_SKIPPED_SUITES + 1))
        SKIPPED_LIST="$SKIPPED_LIST $t"
        echo "**** $t SKIPPED: it did not run (a skip is not a pass) ****"
    else
        TOTAL_FAILED_SUITES=$((TOTAL_FAILED_SUITES + 1))
        FAILED_LIST="$FAILED_LIST $t"
        echo "**** $t FAILED ****"
    fi
    echo
done

echo "===================================="
PASSED_SUITES=$((TOTAL_SUITES - TOTAL_FAILED_SUITES - TOTAL_SKIPPED_SUITES))
if [ "$TOTAL_FAILED_SUITES" -ne 0 ]; then
    echo "$TOTAL_FAILED_SUITES of $TOTAL_SUITES test suites FAILED:$FAILED_LIST"
    [ "$TOTAL_SKIPPED_SUITES" -eq 0 ] || echo "($TOTAL_SKIPPED_SUITES skipped, not run:$SKIPPED_LIST)"
    exit 1
fi
if [ "$TOTAL_SKIPPED_SUITES" -ne 0 ]; then
    echo "$PASSED_SUITES passed, $TOTAL_SKIPPED_SUITES skipped (not run):$SKIPPED_LIST"
    if [ "${HALOW_REQUIRE_REAL:-}" = "1" ]; then
        echo "HALOW_REQUIRE_REAL=1: a skipped suite is a failure."
        exit 1
    fi
    exit 0
fi
echo "ALL $TOTAL_SUITES test suites passed."
exit 0
