#!/usr/bin/env bash
# Helpers for the status snapshot, error catalogue and status service suites.
#
# halow_status_test_setup sources only the libraries these suites test (constants,
# errors, state) and points every path at a fresh temp directory, so the suites stay
# independent of the other subsystems' libraries.

HALOW_STATUS_TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HALOW_STATUS_ADDON_DIR="$(cd "$HALOW_STATUS_TESTS_DIR/.." && pwd)"
HALOW_STATUS_LIB_DIR="$HALOW_STATUS_ADDON_DIR/rootfs/usr/lib/halow"
HALOW_STATUS_SVC_DIR="$HALOW_STATUS_ADDON_DIR/rootfs/etc/services.d/status"

halow_status_test_setup() {
    HALOW_TEST_TMP="$(mktemp -d)"
    export HALOW_RUN_DIR="$HALOW_TEST_TMP/run"
    export HALOW_STATUS_FILE="$HALOW_RUN_DIR/status.json"
    export HALOW_BOOT_ID_PATH="$HALOW_TEST_TMP/boot_id"
    printf '%s\n' "0d6c1a3e-7c55-4c1e-9d55-2f1f7f4b9a01" > "$HALOW_BOOT_ID_PATH"
    unset HALOW_STATE_NOW HALOW_CFG_WIFI_PASSPHRASE HALOW_REDACT_SECRET
    # shellcheck source=/dev/null
    . "$HALOW_STATUS_LIB_DIR/constants.sh"
    # shellcheck source=/dev/null
    . "$HALOW_STATUS_LIB_DIR/errors.sh"
    # shellcheck source=/dev/null
    . "$HALOW_STATUS_LIB_DIR/state.sh"
}

halow_status_test_teardown() {
    if [ -n "${HALOW_TEST_TMP:-}" ]; then
        chmod -R u+w -- "$HALOW_TEST_TMP" 2>/dev/null || :
        rm -rf -- "$HALOW_TEST_TMP"
    fi
}

# json_valid <file> — 0 if the file parses as JSON (python3).
json_valid() {
    python3 -I -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$1" 2>/dev/null
}

# json_get <file> <python expression over d> — prints the value (strings raw, everything
# else as JSON). Prints "<<invalid>>" if the file is not valid JSON.
json_get() {
    python3 -I - "$1" "$2" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    print("<<invalid>>")
    sys.exit(0)
try:
    v = eval(sys.argv[2], {"d": d})
except Exception as exc:
    print("<<error %s>>" % type(exc).__name__)
    sys.exit(0)
print(v if isinstance(v, str) else json.dumps(v))
PY
}

# file_mode <file> — prints the octal permission bits.
file_mode() {
    stat -c '%a' "$1"
}

# count_in_file <file> <fixed string> — prints the number of lines containing it.
count_in_file() {
    local n
    if n="$(grep -c -F -- "$2" "$1" 2>/dev/null)"; then printf '%s\n' "$n"; else printf '0\n'; fi
}
