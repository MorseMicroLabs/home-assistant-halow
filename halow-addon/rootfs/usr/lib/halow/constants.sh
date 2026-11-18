#!/usr/bin/env bash
# halow: constants shared by more than one subsystem. Defines values only (never runs
# anything when sourced) and every value can be overridden from the environment so the
# off-device tests can redirect it. Subsystem-private constants live in their own files.

# Volatile (tmpfs) working directory: the status snapshot, the rendered access-point
# configuration (it holds the passphrase, so it never goes under the persistent /data
# volume that is included in backups) and per-run counters. Lost on every container or
# host restart, by design.
: "${HALOW_RUN_DIR:=/run/halow}"

# The DHCP lease file lives in this directory under the add-on's private /data folder, so
# an ordinary add-on restart does not forget which client holds which address (dnsmasq
# reads the file at start and keeps expiring the leases by their own times). The directory
# is excluded from backups (config.yaml backup_exclude) and is deleted when the add-on is
# uninstalled. It holds client MAC and IP addresses (never host names: dnsmasq is told to
# ignore client-supplied names, and the file is rewritten without them at every start).
# It is separate from HALOW_STATE_DIR, which reconcile interprets and clears.
: "${HALOW_LEASE_DIR:=/data/halow_leases}"
: "${HALOW_STATUS_FILE:=${HALOW_RUN_DIR}/status.json}"

# The private internal bridge the manager creates, owns and removes.
: "${HALOW_BRIDGE_NAME:=halow-br0}"

# Add-on-named firewall chains (one set per address family; the IPv6 chains carry a 6).
: "${HALOW_FW_CHAIN_IN:=HALOW-IN}"
: "${HALOW_FW_CHAIN_FWD_OUT:=HALOW-FWD-OUT}"
: "${HALOW_FW_CHAIN_FWD_IN:=HALOW-FWD-IN}"
: "${HALOW_FW_CHAIN_NAT:=HALOW-NAT}"

# The one supported adapter's USB identity (anything else fails closed).
: "${HALOW_ADAPTER_VENDOR_ID:=325b}"
: "${HALOW_ADAPTER_PRODUCT_ID:=8100}"

# Radio defaults. The development default bandwidth is a development convenience only;
# the customer launch default is chosen after every width has been validated on the
# target device.
: "${HALOW_DEFAULT_BANDWIDTH_MHZ:=1}"
# Upper bound for one automatic channel selection run before the fallback is used. An
# engineering bound, to be set from measurements on the target device.
: "${HALOW_ACS_TIMEOUT_S:=120}"

# The Docker bridge gateway the status service binds to and the only peer it accepts
# (the Supervisor's ingress proxy). Overridable for tests.
: "${HALOW_STATUS_BIND:=172.30.32.1}"
: "${HALOW_STATUS_ALLOW_FROM:=172.30.32.2}"
: "${HALOW_STATUS_USER:=halowstatus}"

# Seconds without a snapshot refresh after which the page reports the snapshot as stale.
: "${HALOW_STATUS_STALE_AFTER_S:=90}"

# The manager mounts a memory-backed filesystem on HALOW_RUN_DIR before anything else and
# then creates this file; the status service waits for it before it starts, so nothing it
# writes can be hidden by the mount. The launcher writes the status service's listening
# port here (readable by the manager) so the manager can check that the port is listening.
: "${HALOW_RUN_READY_FILE:=${HALOW_RUN_DIR}/.ready}"
: "${HALOW_STATUS_PORT_FILE:=${HALOW_RUN_DIR}/status.port}"
# The status service's liveness counter. It lives in its own directory, not under
# HALOW_RUN_DIR, so the unprivileged status user can write exactly that directory and
# nothing else: the launcher (root) creates it, owned by the status user, mode 0700, before
# the server starts; the server replaces the counter file in it atomically (mode 0600)
# about every 5 seconds from its own accept loop; the manager (root) only reads it. The
# launcher ignores an override of this path unless HALOW_STATUS_TEST_MODE=1 (off-device
# tests only); production always uses /run/halow-status/heartbeat.
: "${HALOW_STATUS_HEARTBEAT_DIR:=/run/halow-status}"
: "${HALOW_STATUS_HEARTBEAT_FILE:=${HALOW_STATUS_HEARTBEAT_DIR}/heartbeat}"
# Size limit of the memory-backed run directory.
: "${HALOW_RUN_TMPFS_SIZE:=32m}"
