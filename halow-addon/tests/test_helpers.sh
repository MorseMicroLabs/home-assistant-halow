#!/usr/bin/env bash
# halow test helpers: a tiny, dependency-free assertion framework. No external test
# framework is used — consistent with this project's own established pattern of
# extracting shell functions and executing them directly.

HALOW_TEST_FAILURES=0
HALOW_TEST_COUNT=0

assert_eq() {
    local expected="$1" actual="$2" msg="${3:-}"
    HALOW_TEST_COUNT=$((HALOW_TEST_COUNT + 1))
    if [ "$expected" != "$actual" ]; then
        echo "  FAIL: $msg (expected '$expected', got '$actual')"
        HALOW_TEST_FAILURES=$((HALOW_TEST_FAILURES + 1))
        return 1
    fi
    echo "  ok: $msg"
}

assert_success() {
    local msg="$1"; shift
    HALOW_TEST_COUNT=$((HALOW_TEST_COUNT + 1))
    if "$@" >/tmp/halow_test_out.$$ 2>&1; then
        echo "  ok: $msg"
        rm -f /tmp/halow_test_out.$$
    else
        echo "  FAIL: $msg (expected success; output:)"
        sed 's/^/    | /' /tmp/halow_test_out.$$
        rm -f /tmp/halow_test_out.$$
        HALOW_TEST_FAILURES=$((HALOW_TEST_FAILURES + 1))
        return 1
    fi
}

assert_failure() {
    local msg="$1"; shift
    HALOW_TEST_COUNT=$((HALOW_TEST_COUNT + 1))
    if "$@" >/tmp/halow_test_out.$$ 2>&1; then
        echo "  FAIL: $msg (expected failure, got success)"
        rm -f /tmp/halow_test_out.$$
        HALOW_TEST_FAILURES=$((HALOW_TEST_FAILURES + 1))
        return 1
    else
        echo "  ok: $msg"
        rm -f /tmp/halow_test_out.$$
    fi
}

# assert_exit <expected_code> <msg> <cmd...> — for callers that need to distinguish
# more than success/failure (e.g. this project's own "0 = owned, 2 = usable-but-
# unowned, 1 = failed closed" return-code convention).
assert_exit() {
    local expected="$1" msg="$2"; shift 2
    HALOW_TEST_COUNT=$((HALOW_TEST_COUNT + 1))
    "$@" >/tmp/halow_test_out.$$ 2>&1
    local actual=$?
    if [ "$actual" -eq "$expected" ]; then
        echo "  ok: $msg"
        rm -f /tmp/halow_test_out.$$
    else
        echo "  FAIL: $msg (expected exit $expected, got $actual; output:)"
        sed 's/^/    | /' /tmp/halow_test_out.$$
        rm -f /tmp/halow_test_out.$$
        HALOW_TEST_FAILURES=$((HALOW_TEST_FAILURES + 1))
        return 1
    fi
}

assert_file_exists() {
    local file="$1" msg="$2"
    HALOW_TEST_COUNT=$((HALOW_TEST_COUNT + 1))
    if [ -e "$file" ]; then
        echo "  ok: $msg"
    else
        echo "  FAIL: $msg (file does not exist: $file)"
        HALOW_TEST_FAILURES=$((HALOW_TEST_FAILURES + 1))
        return 1
    fi
}

assert_file_absent() {
    local file="$1" msg="$2"
    HALOW_TEST_COUNT=$((HALOW_TEST_COUNT + 1))
    if [ ! -e "$file" ]; then
        echo "  ok: $msg"
    else
        echo "  FAIL: $msg (file unexpectedly exists: $file)"
        HALOW_TEST_FAILURES=$((HALOW_TEST_FAILURES + 1))
        return 1
    fi
}

# halow_test_setup — sources every lib file and points every path constant at a fresh
# disposable temp directory, so tests never touch the real host filesystem.
#
# Deliberately does NOT pre-create HALOW_FW_DIR: an earlier version of this harness
# pre-created every destination directory in setup, which hid the directory-ownership
# tracking (nothing was ever actually created by the code under test, so nothing was ever
# actually removed either). Each test creates only the directories it specifically needs.
halow_test_setup() {
    HALOW_TEST_TMP="$(mktemp -d)"
    export HALOW_STATE_DIR="$HALOW_TEST_TMP/data"
    export HALOW_FW_DIR="$HALOW_TEST_TMP/host-firmware/morse"
    export HALOW_FW_SEARCH_DIR_HOST="$HALOW_TEST_TMP/host-firmware"
    export HALOW_FW_SYSFS_PATH="$HALOW_TEST_TMP/fake-sysfs-firmware-class-path"
    export HALOW_ARTIFACTS_DIR="$HALOW_TEST_TMP/artifacts"
    # A fresh, normally-empty fake /sys/class/net — any interface name is correctly
    # reported as not existing unless a test explicitly creates its own directory under
    # here, exactly mirroring a real kernel that has never heard of that interface.
    export HALOW_SYS_CLASS_NET_DIR="$HALOW_TEST_TMP/fake-sys-class-net"
    # Hermetic /sys/module: never consult the test host's real one (built-in-module detection).
    export HALOW_SYS_MODULE_DIR="$HALOW_TEST_TMP/fake-sys-module"
    # Volatile run directory (status snapshot, rendered configuration, lease file, counters).
    export HALOW_RUN_DIR="$HALOW_TEST_TMP/run"
    export HALOW_STATUS_FILE="$HALOW_RUN_DIR/status.json"
    # Persistent DHCP lease directory (the product's is /data/halow_leases).
    export HALOW_LEASE_DIR="$HALOW_TEST_TMP/lease-data"
    # Host facts the manager reads: the kernel's per-boot id and the IPv4 forwarding flag
    # (verify-only). Plain files here; a test writes what it needs.
    export HALOW_BOOT_ID_FILE="$HALOW_TEST_TMP/fake-proc-boot_id"
    export HALOW_IP_FORWARD_FILE="$HALOW_TEST_TMP/fake-proc-ip_forward"
    export HALOW_LIB_DIR
    mkdir -p "$HALOW_SYS_MODULE_DIR"
    mkdir -p "$HALOW_STATE_DIR" "$HALOW_ARTIFACTS_DIR/bcf" "$HALOW_SYS_CLASS_NET_DIR"
    : > "$HALOW_FW_SYSFS_PATH"
    # Source the shared constants first, then the established libraries in their original
    # order (skipping any that no longer exist), then every other library in the directory
    # (alphabetical), so a new library is available to every test without editing this list.
    # Libraries only define functions and constants; none runs anything when sourced.
    . "$HALOW_LIB_DIR/constants.sh"
    local _sourced=" constants "
    for _lib in common checksum ownership validate firmware nm_unmanaged iface_detect module_load hostapd_config network_backend backend backend_routed_nat stations rollback health; do
        if [ -f "$HALOW_LIB_DIR/${_lib}.sh" ]; then
            # shellcheck source=/dev/null
            . "$HALOW_LIB_DIR/${_lib}.sh"
            _sourced="${_sourced}${_lib} "
        fi
    done
    local _f
    for _f in "$HALOW_LIB_DIR"/*.sh; do
        _lib="$(basename "$_f" .sh)"
        case "$_sourced" in *" $_lib "*) continue ;; esac
        # shellcheck source=/dev/null
        . "$_f"
    done
    # The build's default backend is registered; tests that exercise rollback or the station
    # lifecycle go through the same contract the real scripts use.
    HALOW_BACKEND_NAME=""
    halow_backend_register_default
}

HALOW_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../rootfs/usr/lib/halow" && pwd)"

halow_test_teardown() {
    [ -n "${HALOW_TEST_TMP:-}" ] && rm -rf -- "$HALOW_TEST_TMP"
}
