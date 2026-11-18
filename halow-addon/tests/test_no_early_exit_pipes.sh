#!/usr/bin/env bash
# Static guard: under bashio's `set -o pipefail`, a pipeline whose READER exits early
# (`| grep -q`, `| grep -m`, `| head`, `| sed -n 'Nq'`, `| awk '...exit...'`) can report
# failure even though the reader succeeded, because the WRITER is killed by SIGPIPE. A live
# live run was bitten by exactly this (`lsmod | grep -q`: 299/300 false "absent"
# on the real Green). A pipeline into the logging sink (`| halow_log_pipe`) also leaks
# the sink's status into the result (use halow_run_logged). This test fails if any
# production shell or in-image test helper reintroduces one of these. Use
# `cmd="$(...)"` + `grep ... <<< "$cmd"` (see halow_module_state) instead.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./test_helpers.sh

echo "== test_no_early_exit_pipes =="
ROOT="$(cd .. && pwd)"

# One regex per hazard class (ERE). A "pipe into X" where X is an early-exit reader.
PATTERNS=(
    # grep with a quiet / max-count option ANYWHERE in its own arguments (not only first)
    '\|[[:space:]]*grep[[:space:]]([^|]*[[:space:]])?(-[A-Za-z]*[qm][A-Za-z0-9]*|--quiet|--silent|--max-count)([[:space:]=]|$)'
    # head
    '\|[[:space:]]*head([[:space:]]|$)'
    # sed that quits early
    '\|[[:space:]]*sed[[:space:]]([^|]*[[:space:]])?[^|]*[;{[:space:]'"'"'"]?[0-9$]*q([[:space:];}'"'"'"]|$)'
    # awk that exits early
    '\|[[:space:]]*awk[[:space:]][^|]*exit'
    # pipe into the logging sink
    '\|[[:space:]]*halow_log_pipe'
)
# One sample per class: the guard MUST flag each (proves every alternative can fail).
SAMPLES=(
    "    if lsmod | grep -q '^mac80211 '; then"
    "    x | grep -E -q 'a'"
    "    x | grep -e a -q"
    "    x | grep -F -x -q a"
    "    x | grep -m1 a"
    "    x | head -n1"
    "    x | sed -n '1p;q'"
    "    x | awk '/a/{exit}'"
    "    insmod a.ko 2>&1 | halow_log_pipe"
)
# And NEGATIVE samples that must NOT be flagged (reads everything / no early exit).
NEGATIVES=(
    "    x | grep -c ."
    "    printf a | wc -l | tr -d ' '"
    "    x | sed 's/a/b/'"
    "    x | awk '{print \$1}'"
)

matches_any() { # matches_any <line>
    local line="$1" p
    for p in "${PATTERNS[@]}"; do
        if grep -E -q -- "$p" <<< "$line"; then return 0; fi
    done
    return 1
}

for s in "${SAMPLES[@]}"; do
    HALOW_TEST_COUNT=$((HALOW_TEST_COUNT + 1))
    if matches_any "$s"; then echo "  ok: guard flags: $s"; else echo "  FAIL: guard does NOT flag: $s"; HALOW_TEST_FAILURES=$((HALOW_TEST_FAILURES + 1)); fi
done
for s in "${NEGATIVES[@]}"; do
    HALOW_TEST_COUNT=$((HALOW_TEST_COUNT + 1))
    if matches_any "$s"; then echo "  FAIL: guard wrongly flags: $s"; HALOW_TEST_FAILURES=$((HALOW_TEST_FAILURES + 1)); else echo "  ok: guard allows: $s"; fi
done

files=( "$ROOT"/rootfs/usr/lib/halow/*.sh "$ROOT"/rootfs/usr/lib/halow/status/*.sh "$ROOT"/rootfs/etc/services.d/manager/run "$ROOT"/rootfs/etc/services.d/manager/finish "$ROOT"/rootfs/etc/services.d/status/run "$ROOT"/rootfs/etc/services.d/status/finish "$ROOT"/tests/image_*.sh )
hits=""
for f in "${files[@]}"; do
    while IFS= read -r line; do
        # skip comment-only lines
        body="${line#*:}"; trimmed="${body#"${body%%[![:space:]]*}"}"
        case "$trimmed" in "#"*) continue ;; esac
        # the sink itself reads ALL of its input; halow_run_logged feeds it deliberately (`|| true`)
        case "$trimmed" in *"halow_log_pipe || true"*) continue ;; esac
        for p in "${PATTERNS[@]}"; do
            if grep -E -q -- "$p" <<< "${line#*:}"; then hits="${hits}$(basename "$f"):${line}"$'\n'; break; fi
        done
    done < <(grep -n '|' "$f" 2>/dev/null)
done
HALOW_TEST_COUNT=$((HALOW_TEST_COUNT + 1))
if [ -z "$hits" ]; then
    echo "  ok: no early-exit-reader or log-sink pipeline in production shell or in-image test helpers"
else
    echo "  FAIL: early-exit-reader / log-sink pipelines found (pipefail + SIGPIPE hazard):"
    printf '%s' "$hits" | sed 's/^/    /'
    HALOW_TEST_FAILURES=$((HALOW_TEST_FAILURES + 1))
fi

# The manager must handle a failing dmesg explicitly (no bare command substitution under errexit).
HALOW_TEST_COUNT=$((HALOW_TEST_COUNT + 1))
if grep -q 'if ! _dmesg_watermark="$(halow_dmesg_watermark)"; then' "$ROOT/rootfs/usr/lib/halow/manager.sh" \
   && grep -q 'if ! _dmesg_new="$(halow_dmesg_since "$_dmesg_watermark")"; then' "$ROOT/rootfs/usr/lib/halow/manager.sh"; then
    echo "  ok: the manager tests the dmesg helpers' status explicitly at both call sites"
else
    echo "  FAIL: the manager no longer tests the dmesg helpers' status explicitly"
    HALOW_TEST_FAILURES=$((HALOW_TEST_FAILURES + 1))
fi

echo "test_no_early_exit_pipes: $((HALOW_TEST_COUNT - HALOW_TEST_FAILURES))/$HALOW_TEST_COUNT passed"
exit $([ "$HALOW_TEST_FAILURES" -eq 0 ] && echo 0 || echo 1)
