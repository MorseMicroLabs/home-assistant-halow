#!/usr/bin/env bash
# halow common library: logging and shared path/constant defaults.
# Sourced by every other halow lib file and by run/finish.
#
# Logging works both inside the add-on container (where bashio is available) and in the
# off-device test harness (where it is not) — tests see plain, prefixed stderr lines.

halow_log_info() {
    if command -v bashio::log.info >/dev/null 2>&1; then
        bashio::log.info "$*"
    else
        printf '[halow] INFO: %s\n' "$*" >&2
    fi
}

halow_log_warning() {
    if command -v bashio::log.warning >/dev/null 2>&1; then
        bashio::log.warning "$*"
    else
        printf '[halow] WARN: %s\n' "$*" >&2
    fi
}

halow_log_error() {
    if command -v bashio::log.error >/dev/null 2>&1; then
        bashio::log.error "$*"
    else
        printf '[halow] ERROR: %s\n' "$*" >&2
    fi
}

# Pipe helper: logs each line of stdin at info level, without ever echoing a secret.
# Callers must never pipe anything that could contain the WiFi passphrase through this.
halow_log_pipe() {
    while IFS= read -r _line; do
        halow_log_info "$_line"
    done
}

# halow_process_comm <pid> — isolated into its own function specifically so the
# off-device test harness can override it: most test scenarios stub a process as a shell
# function for simplicity and only need "a running process" for ownership/idempotency
# logic, not one whose real kernel `comm` field genuinely reads a specific binary name
# (which only a real, directly-exec'd binary of that exact name provides). Shared by
# every process-identity check in this codebase (dnsmasq, hostapd_s1g) — not specific to
# either one.
halow_process_comm() {
    cat "/proc/$1/comm" 2>/dev/null || echo ""
}

# halow_process_cmdline_contains <pid> <exact_arg>
# Isolated into its own function, matching halow_process_comm's own rationale above, so
# the off-device test harness can override it without needing a real process whose real
# argv happens to match. /proc/<pid>/cmdline is NUL-separated, one argument per field —
# `tr` converts each embedded NUL into a newline so `grep -qxF` can match <exact_arg> as
# a single, whole argument, never a substring of a longer one. Three-way result, never
# conflated: 0 = read and matched; 1 = read but did not match; 2 = could not be read at
# all. Every caller (network_backend.sh's dnsmasq identity check, hostapd_config.sh's
# hostapd_s1g identity check) must treat all three as genuinely distinct — in particular,
# an unreadable cmdline (2) must never be treated as either a positive match or as
# positive evidence of a mismatch; it is simply unknown.
halow_process_cmdline_contains() {
    local pid="$1" needle="$2"
    [ -r "/proc/$pid/cmdline" ] || return 2
    # NOT `tr ... | grep -qxF`: under bashio's `set -o pipefail`, grep -q exits at the first
    # match and the writer can die of SIGPIPE, turning a genuine match into a false "no
    # match" (measured live for the same pattern with lsmod; see module_load.sh's
    # halow_module_state). Capture first, then search a here-string (no pipe).
    local _lines
    if ! _lines="$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null)"; then
        return 2
    fi
    grep -qxF -- "$needle" <<< "$_lines"
}

# halow_path_still_present <path>
# True if <path> still names ANYTHING at all — a real file/directory, OR a symbolic link,
# INCLUDING a dangling one. Plain `[ -e <path> ]` alone is not sufficient to verify a
# removal actually succeeded: `-e` follows symlinks and reports false for a dangling one,
# so a broken symlink left behind after an `rm -f` that failed to remove it could be
# wrongly read as "confirmed absent." Used everywhere this codebase verifies a removal by
# re-checking the filesystem afterward, rather than trusting `rm`'s own exit status alone.
halow_path_still_present() {
    [ -e "$1" ] || [ -L "$1" ]
}

# halow_wait_for_pattern <file> <pattern> [<timeout_seconds>] [<watch_pid>]
# Polls <file> once a second for a line containing <pattern>. Returns 0 on match, 1 on
# timeout, 2 if <watch_pid> is given and that process has already exited (so a caller
# waiting for e.g. hostapd's own AP-ENABLED line does not sit out the full timeout after
# hostapd itself has already died).
halow_wait_for_pattern() {
    local file="$1" pattern="$2" timeout="${3:-30}" watch_pid="${4:-}" waited=0
    while [ "$waited" -lt "$timeout" ]; do
        if [ -f "$file" ] && grep -q -- "$pattern" "$file" 2>/dev/null; then
            return 0
        fi
        if [ -n "$watch_pid" ] && ! kill -0 "$watch_pid" 2>/dev/null; then
            return 2
        fi
        sleep 1
        waited=$((waited + 1))
    done
    return 1
}

# ---------------------------------------------------------------------------------------
# Kernel-log scoping for "did THIS module load produce the evidence"
#
# DEFECT THIS REPLACES (observed on a long-running device): the earlier design counted `dmesg` lines
# before the load and took `tail -n +N+1` afterwards. The kernel log is a fixed-size ring
# that drops its OLDEST records when full, so on a long-running host the line count does
# not grow (measured: 3495 lines before a load, 3468 after, while 93 new
# records had been written); the slice came out empty and every start failed closed until
# a reboot. A line count is not a position in a ring that evicts from the front.
#
# DESIGN. The marker is the NEWEST record in the log (its complete line, including the
# kernel's own boot-relative timestamp), taken immediately before the load. The ring
# always keeps a contiguous suffix of the records ever written, evicting only the oldest,
# so if that marker record is still present afterwards then EVERY record written after it
# is present, in order, and exactly those are "this attempt". Eviction of old lines, however
# many, cannot shift the slice. If the marker is gone (a whole ring of new records, or
# someone cleared the log, or a reboot) the records between the marker and the first
# surviving one are unknown, so the slice cannot be proven and the read FAILS CLOSED.
# Records of earlier loads, which are before the marker, can therefore never be mistaken
# for this attempt's, and a second start gets a fresh marker after the first one's records.
#
# WHY NOT /dev/kmsg SEQUENCE NUMBERS. They would be the stronger primitive, but the image's
# dmesg is BusyBox (klogctl(2), needs CAP_SYSLOG, which the add-on holds), whose output has
# no sequence numbers, and a default container has no /dev/kmsg node at all (checked in the
# built image; whether the Home Assistant Supervisor adds one is not established, so it is
# not relied on). The kernel timestamp is used as the second, independent check: a record
# after the marker that is OLDER than the marker proves a different log (reboot/clear) and
# also fails closed. A marker without a kernel timestamp (printk timestamps compiled out)
# cannot be told apart from an identical repeated line, so that also fails closed.
#
# All parsing is in pure functions that take text (halow_klog_ts_us,
# halow_klog_after_marker); halow_dmesg_watermark / halow_dmesg_since are thin readers.
# After a failure HALOW_KLOG_REASON holds a one-line reason. The readers run in command
# substitutions, where that variable is lost, so halow_klog_report_reason also prints it on
# stderr (never stdout, which callers capture) and writes it to HALOW_KLOG_REASON_FILE when
# that is set (the manager sets it and shows the text in the attention detail).
# ---------------------------------------------------------------------------------------

# halow_klog_ts_us <line> — prints the line's kernel timestamp ("[  203.561224] ...") in
# microseconds; returns 1 (printing nothing) when the line has no such timestamp.
halow_klog_ts_us() {
    local line="${1:-}" re='^\[[[:space:]]*([0-9]+)\.([0-9]{6})\]'
    if [[ "$line" =~ $re ]]; then
        printf '%s' "$(( 10#${BASH_REMATCH[1]} * 1000000 + 10#${BASH_REMATCH[2]} ))"
        return 0
    fi
    return 1
}

# halow_klog_after_marker <marker_line> <log_text>
# PURE. Prints the records of <log_text> after the LAST line equal to <marker_line>.
# Status: 0 ok (possibly no records), 1 marker unusable (empty / no timestamp),
# 2 marker not found in the log (records lost or log replaced: cannot be proven),
# 3 a record after the marker is older than the marker by more than the tolerance below
# (a different log).
# TOLERANCE (status 3). The marker must equal a whole timestamped line, so a stale or
# foreign log cannot pass on timestamps alone; this check is only a SECONDARY detector of a
# clock reversal (a reboot or a replaced log that happens to contain the marker line). It
# must also not fire on benign ordering: printk takes a record's timestamp before it
# reserves the record's place in the ring, so on a multi-processor host a record stored
# later can carry a slightly older timestamp, and timestamps come from a clock that is
# only coarsely synchronised between CPUs. HALOW_KLOG_SKEW_US (default 100000, i.e. 100 ms,
# far above any such inversion and far below the seconds between two loads or a reboot) is
# the largest accepted inversion.
: "${HALOW_KLOG_SKEW_US:=100000}"
halow_klog_after_marker() {
    local marker="${1:-}" log_text="${2:-}" mts lts i last=-1 n
    local -a lines
    HALOW_KLOG_REASON=""
    if [ -z "$marker" ] || ! mts="$(halow_klog_ts_us "$marker")"; then
        HALOW_KLOG_REASON="the pre-load kernel-log marker is empty or carries no kernel timestamp"
        return 1
    fi
    mapfile -t lines <<< "$log_text"
    n=${#lines[@]}
    for (( i = n - 1; i >= 0; i-- )); do
        if [ "${lines[i]}" = "$marker" ]; then
            last=$i
            break
        fi
    done
    if [ "$last" -lt 0 ]; then
        HALOW_KLOG_REASON="the pre-load kernel-log marker is no longer in the kernel log (records may have been lost or the log replaced), so this attempt's records cannot be proven"
        return 2
    fi
    for (( i = last + 1; i < n; i++ )); do
        if lts="$(halow_klog_ts_us "${lines[i]}")" && [ "$((lts + HALOW_KLOG_SKEW_US))" -lt "$mts" ]; then
            HALOW_KLOG_REASON="a kernel-log record after the marker is older than the marker by more than ${HALOW_KLOG_SKEW_US} us (a different log)"
            return 3
        fi
        printf '%s\n' "${lines[i]}"
    done
    return 0
}

# halow_klog_report_reason — makes HALOW_KLOG_REASON visible to the operator. The readers
# below normally run inside a command substitution, where a variable they set is lost and
# only their stdout is captured, so the reason goes (1) to stderr, never stdout, and (2) to
# the file named by HALOW_KLOG_REASON_FILE when that is set (the manager sets it and puts
# the text into the attention detail).
halow_klog_report_reason() {
    printf '[halow] kernel-log: %s\n' "${HALOW_KLOG_REASON:-}" >&2
    if [ -n "${HALOW_KLOG_REASON_FILE:-}" ]; then
        printf '%s\n' "${HALOW_KLOG_REASON:-}" > "$HALOW_KLOG_REASON_FILE" 2>/dev/null || true
    fi
    return 0
}

# halow_dmesg_watermark — prints the marker (the newest kernel-log record that carries a
# kernel timestamp, whole line) for use with halow_dmesg_since, taken immediately before the
# action being checked. The name is historical; it is NOT a line count any more (see above).
#
# Returns non-zero (printing nothing) when `dmesg` cannot be read, is empty, or no record
# has a kernel timestamp -- an explicit status, never a silent pipeline failure:
# under bashio's `set -o pipefail` + errexit a bare `x="$(dmesg | tail -n 1)"` with a
# failing dmesg would abort `run` with no log line and no rollback trigger. Callers must
# test the status (`run` does, and fails closed).
halow_dmesg_watermark() {
    local out line newest=""
    HALOW_KLOG_REASON=""
    if ! out="$(dmesg 2>/dev/null)"; then
        HALOW_KLOG_REASON="the kernel log (dmesg) cannot be read"
        halow_klog_report_reason
        return 1
    fi
    # The newest line that carries a kernel timestamp is the marker; a newer line without
    # one (e.g. a continuation line) just becomes part of the window, which is safe.
    while IFS= read -r line; do
        if [ -n "$line" ] && halow_klog_ts_us "$line" >/dev/null; then
            newest="$line"
        fi
    done <<< "$out"
    if [ -z "$newest" ]; then
        HALOW_KLOG_REASON="the kernel log is empty or no record has a kernel timestamp, so no usable marker can be taken"
        halow_klog_report_reason
        return 1
    fi
    printf '%s' "$newest"
}

# halow_dmesg_since <marker>
# Prints only the dmesg records written after <marker> (as returned by halow_dmesg_watermark
# from the same boot, captured immediately before the action being checked, e.g. a module
# load). Checking the driver's own success/failure record only in this window prevents a
# stale record from an earlier load being mistaken for the current one. Fails closed (status
# 1 unreadable/unusable marker, 2 marker lost, 3 inconsistent timestamps; HALOW_KLOG_REASON
# says which) whenever the window cannot be proven to be complete.
halow_dmesg_since() {
    local marker="${1:-}" out rc
    HALOW_KLOG_REASON=""
    if ! out="$(dmesg 2>/dev/null)"; then
        HALOW_KLOG_REASON="the kernel log (dmesg) cannot be read"
        halow_klog_report_reason
        return 1
    fi
    if halow_klog_after_marker "$marker" "$out"; then
        return 0
    else
        rc=$?
    fi
    halow_klog_report_reason
    return "$rc"
}

# halow_crc32_file <file> — prints the file's standard (zlib/IEEE 802.3) CRC-32 as 0x%08x,
# the form the Morse driver logs ("crc32 0xc8af8c0d"). Pure bash + od so it needs no new
# executable in the add-on's AppArmor profile; intended for the small board file only (a
# few kilobytes; it is not fast for the main firmware).
halow_crc32_file() {
    local f="${1:-}" out b i j c crc=4294967295
    local -a tbl
    [ -n "$f" ] && [ -r "$f" ] || return 1
    out="$(od -An -v -tu1 "$f")" || return 1
    for (( i = 0; i < 256; i++ )); do
        c=$i
        for (( j = 0; j < 8; j++ )); do
            if (( c & 1 )); then c=$(( (c >> 1) ^ 3988292384 )); else c=$(( c >> 1 )); fi
        done
        tbl[i]=$c
    done
    for b in $out; do
        crc=$(( (crc >> 8) ^ tbl[(crc ^ b) & 255] ))
    done
    printf '0x%08x' "$(( crc ^ 4294967295 ))"
}

# halow_run_logged <command...>
# Runs the command, logs every line of its combined output through halow_log_info, and
# returns THE COMMAND'S OWN exit status. Replaces `cmd 2>&1 | halow_log_pipe` used as an
# `if` condition: under `set -o pipefail` that pipeline's status is the RIGHTMOST non-zero
# one, so a logging hiccup after a successful `insmod`/`modprobe` read as "the load failed"
# and left a loaded, never-owned module behind (found during review).
halow_run_logged() {
    local out rc
    if out="$("$@" 2>&1)"; then
        rc=0
    else
        rc=$?
    fi
    if [ -n "$out" ]; then
        printf '%s\n' "$out" | halow_log_pipe || true
    fi
    return "$rc"
}

# --- Default paths/constants. Every one is overridable via environment variable so the
# off-device test harness can redirect all of this to a disposable temp directory instead
# of the real host filesystem. ---

# Documented, Supervisor-provided persistent storage. The add-on's own ownership
# records, rendered config, and runtime PID/lock files live here — never the firmware or
# udev-rule artefacts themselves, which target host filesystem locations outside any
# interface this project's add-on options currently expose (see README.md's own
# "Known blocker" section for exactly what is and is not reachable from inside this
# container under its current configuration).
: "${HALOW_STATE_DIR:=/data/halow_state}"

# Firmware is staged inside this add-on's own documented, always-mounted /data
# persistent volume (never an undocumented host filesystem location), and the host
# kernel's firmware-loader search path is pointed at it fresh at every startup (see
# module_load.sh's halow_set_firmware_search_path, called from run before loading
# morse.ko). Confirmed directly from Linux kernel source (v6.18.52,
# drivers/base/firmware_loader/main.c): this extra search directory is tried FIRST but
# does not replace the kernel's own default search paths (/lib/firmware/updates,
# /lib/firmware, etc.) — other drivers'/add-ons' firmware requests on the shared host are
# unaffected while this is set. This superseded the original design's own undocumented
# `/mnt/data/supervisor/firmware` host-location write, confirmed infeasible (no Supervisor
# mount, documented or undocumented, exposes that path into an add-on container).
#
# morse_driver's own public source (firmware.h: MORSE_FW_DIR "morse") requests firmware
# by the name "morse/<file>", so files must sit in a "morse" subdirectory of whatever
# directory the sysfs search-path parameter points at. HALOW_FW_DIR below is that
# subdirectory itself (container-local — where files are actually written);
# HALOW_FW_SEARCH_DIR_HOST, further below, is its PARENT's host-absolute equivalent
# (what actually gets written to the sysfs node, since the kernel resolves firmware
# requests against the host's own filesystem view, never the calling container's).
: "${HALOW_FW_DIR:=/data/halow_fw/morse}"
: "${HALOW_FW_MAIN_NAME:=mm8108b2-rl.bin}"
: "${HALOW_FW_BCF_NAME:=bcf_boardtype_0807.bin}"

# Supervisor's own container-environment construction (confirmed from Supervisor
# 2026.09.2 and 2026.09.3 source — identical on this point across both tagged releases,
# diffed directly, commits 94b4a0b..64ea3be — supervisor/docker/app.py's own
# `environment` property) does not pass this add-on's own host-absolute /data path into
# the container — there is no documented or discoverable environment variable for it.
#
# Hardcoding a single, fixed value here is NOT safe: Supervisor's own installed-app slug
# is `<repository>_<config.yaml slug>`, not the bare config.yaml slug alone — confirmed
# directly from source, `supervisor/store/data.py`: `app_slug = f"{repository}_
# {app[ATTR_SLUG]}"`, and `supervisor/const.py`: `REPOSITORY_LOCAL = "local"`. An add-on
# installed the standard way for an unpublished, desk-only development build like this one (dropped
# into Supervisor's own "local" add-on folder, with no registered repository) is
# therefore actually identified as `local_morse_micro_halow_ap`, not
# `morse_micro_halow_ap`: confirmed independently along a second code path too:
# `supervisor/apps/app.py`'s `path_extern_data` property uses exactly this same
# `self.slug` for the add-on's own host-absolute /data path
# (`<path_extern_supervisor>/apps/data/<slug>`). Assuming the bare, unprefixed slug would
# silently compute the WRONG host path.
#
# This value is therefore DERIVED AT RUNTIME, not hardcoded here — see
# halow_derive_installed_slug, below, and run's own use of it. Only the Supervisor-share
# root is a fixed constant, and it is no longer a carried-over assumption either: directly
# confirmed this pass from Home Assistant OS's own public source
# (`home-assistant/operating-system`, tag `18.3`,
# `buildroot-external/rootfs-overlay/usr/sbin/haos-supervisor`): `SUPERVISOR_DATA=
# /mnt/data/supervisor` is the literal value Supervisor's own launcher script exports as
# `SUPERVISOR_SHARE` when starting the Supervisor container itself.
: "${HALOW_SUPERVISOR_SHARE_HOST:=/mnt/data/supervisor}"

# HALOW_FW_SEARCH_DIR_HOST itself has NO static default — run computes and exports it
# (via halow_derive_installed_slug, below) before it is first used, unless a caller
# (e.g. the test harness) has already set it explicitly. See README.md's own "Known
# blocker" section for what, if anything, still needs a live-Green confirmation.

# halow_derive_installed_slug [<hostname_text>]
# Supervisor sets this add-on's own container hostname to its full, repository-qualified
# slug with underscores replaced by hyphens — confirmed directly from source,
# `supervisor/apps/model.py`: `hostname = self.slug.replace("_", "-")` — and this add-on
# requests no `host_uts`, so Supervisor's own per-app hostname is what the container
# actually receives (`supervisor/docker/app.py`: `hostname = None if self.uts_mode else
# self.app.hostname`), not the host's own hostname. Reversing that one substitution
# recovers the real, currently-installed slug at runtime, without hardcoding which
# repository this add-on was installed from. This reversal is lossless only because this
# add-on's own expected slug (`morse_micro_halow_ap`) and the `local` repository prefix
# contain no hyphens of their own — a documented, narrow assumption, not a fully general
# solution, and the caller below still sanity-checks the result rather than trusting it
# blindly. Prints the derived slug on success; returns 1 if no hostname could be read at
# all by any means.
halow_derive_installed_slug() {
    local hostname_text="${1:-}"
    if [ -z "$hostname_text" ]; then
        hostname_text="$(cat /etc/hostname 2>/dev/null || true)"
    fi
    if [ -z "$hostname_text" ]; then
        hostname_text="$(hostname 2>/dev/null || true)"
    fi
    if [ -z "$hostname_text" ]; then
        halow_log_error "slug-derive: could not read this container's own hostname by any means"
        return 1
    fi
    printf '%s' "${hostname_text//-/_}"
}

# The host kernel's own live firmware-loader search-path parameter (module_param_string,
# re-read on every firmware lookup, confirmed from kernel source — no reboot or module
# reload needed for a change to take effect). Global, host-wide, un-namespaced state —
# see module_load.sh's own halow_set_firmware_search_path/_restore_firmware_search_path
# for how this package captures and restores its prior value, and minimises the window
# it holds it for.
: "${HALOW_FW_SYSFS_PATH:=/sys/module/firmware_class/parameters/path}"

# development-build-only accommodation (2026-10-20) — NOT a production/customer
# mechanism. A live Green empirically demonstrated that neither a zero-byte write nor a
# single-NUL-byte write actually restores HALOW_FW_SYSFS_PATH to its true empty
# baseline, for reasons that remain unexplained after kernel-source review and read-only
# on-device diagnosis (see module_load.sh's own "EMPTY VALUES ARE REFUSED" / "INERT SENTINEL"
# header comments for the full record — an earlier, incorrect claim that an upstream
# kernel selftest corroborates the NUL-byte technique has been withdrawn; that selftest's
# own `printf '\000'` usage concerns an unrelated parameter, an empty firmware REQUEST
# NAME, not this search-PATH parameter). Rather than retry further unproven live write
# techniques, a safe, clearly-named, inert sentinel VALUE is installed instead whenever
# the node's true recorded prior value was empty: confirmed from kernel source
# (drivers/base/firmware_loader/main.c's own `fw_get_filesystem_firmware`, fetched and
# read directly this same investigation) that a custom search path which fails to
# resolve a requested firmware file (because nothing exists there) simply falls through
# to the kernel's own remaining default search paths, in their existing order — the same
# guarantee already relied on for the ADD-ON's own non-sentinel use of this parameter.
# This path itself is never created, deleted, or modified by this add-on — it is used
# purely as an inert STRING VALUE in the sysfs parameter; its own non-existence as a real
# path must be positively confirmed from the HOST's own filesystem view before use (the
# add-on container has no visibility into the host's own /run namespace to check this
# itself — confirmed the same way this project already established that firmware
# resolution itself always uses the host's own init mount namespace, never the
# container's). This is functionally safe for this bounded, time-limited development build test
# window, but is explicitly NOT accepted as the production/customer solution, and is NOT
# an exact restoration — see "firmware_path_reboot_required" (module_load.sh) for how
# that distinction is tracked and honestly reported.
: "${HALOW_FW_SEARCH_SENTINEL:=/run/halow-firmware-search-disabled}"

# A package-created host udev rule, named uniquely to this add-on so ownership can never
# be confused with any other package's or the customer's own supported configuration
# mechanism's rule.
: "${HALOW_UDEV_RULE_PATH:=/run/udev/rules.d/90-halow-nm-unmanaged.rules}"

# Build-time-staged artifacts inside the container image.
: "${HALOW_ARTIFACTS_DIR:=/opt/halow/artifacts}"

export HALOW_STATE_DIR HALOW_FW_DIR HALOW_FW_MAIN_NAME HALOW_FW_BCF_NAME \
    HALOW_SUPERVISOR_SHARE_HOST HALOW_FW_SYSFS_PATH HALOW_FW_SEARCH_SENTINEL \
    HALOW_UDEV_RULE_PATH HALOW_ARTIFACTS_DIR
# HALOW_FW_SEARCH_DIR_HOST is deliberately NOT given a default above and is exported
# only once it has an actual value (set by run, via halow_derive_installed_slug, or by
# the test harness) — exporting it unset here would make `: "${HALOW_FW_SEARCH_DIR_HOST:=}"`-style
# checks elsewhere silently treat "never set" the same as "set to empty."
