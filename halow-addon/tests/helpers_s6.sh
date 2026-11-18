#!/usr/bin/env bash
# Real s6-svstat output for the tests. tests/fixtures/s6-svstat-real.txt holds what the real
# s6-svstat of the image printed for a service in each state; every fake of s6-svstat in
# the suites is built from it, so a fake cannot drift from the real program.

S6_FIXTURE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fixtures/s6-svstat-real.txt"

# s6_fixture_rc <section> — the exit status the real program had.
s6_fixture_rc() {
    awk -v n="$1" '$1 == "@@" && $2 == n { sub(/rc=/, "", $3); print $3; exit }' "$S6_FIXTURE"
}

# s6_fixture_out <section> — its output, exactly (trailing spaces kept).
s6_fixture_out() {
    awk -v n="$1" '$1 == "@@" && $2 == n { p = 1; next } $1 == "@@" && $2 == "end" { p = 0 } p' "$S6_FIXTURE"
}

# s6_fixture_has <section> — 0 when the fixture has it (so a typo in a test cannot pass).
s6_fixture_has() {
    awk -v n="$1" '$1 == "@@" && $2 == n { f = 1 } END { exit !f }' "$S6_FIXTURE"
}

# s6_fixture_print <section> <pid> — what the fake prints for that state: the real output,
# with the pid of a `true <pid>` line replaced by <pid> (the only edit; the format is
# untouched). Output goes to stdout, or to stderr when the real program failed.
s6_fixture_print() {
    local rc out
    rc="$(s6_fixture_rc "$1")"
    out="$(s6_fixture_out "$1" | sed "s/^true [0-9][0-9]*\$/true $2/")"
    if [ "$rc" = "0" ]; then printf '%s\n' "$out"; else printf '%s\n' "$out" >&2; fi
    return "$rc"
}
