# Operations and engineering notes

This document is for people who install the app from a local apps folder, build it, or work on it. Customers
find setup, settings, and troubleshooting in README.md. Nothing here is needed to use the app.

## Installing the app

Customers install the app from the Morse Micro Labs repository in the Home Assistant app store.
`config.yaml` names the prebuilt image (`image:`, without a tag): the Supervisor pulls that image
from the registry, with the tag equal to the app's `version`. The image is not built on the
Home Assistant system. It cannot be built from this repository alone, because the kernel
modules, firmware and hostapd binaries it carries are not in Git; see "Building and testing"
and `LOCAL-IMAGE-BUILD.md`.

## Installing from a local apps folder (engineering use)

Because `config.yaml` has an `image:` key, a copy in the local apps folder makes the
Supervisor pull the published image too; it does not build the local `Dockerfile`. To test
something else, either make the image you built available to the Green's Docker under the
name and tag the manifest names, or, in a private copy only, remove the `image:` line so that the
Supervisor builds from the `Dockerfile`. That build needs:

- the bundled artifacts already staged in `artifacts/` (run `build.sh` with the separately
  built artifact bundle on a build machine first). They are not in the repository, and the
  build fails without them;
- network access from the Home Assistant system to the base image registry (`ghcr.io`) and to the
  Alpine package repository;
- the exact pinned Alpine package versions still being served by that repository.

Steps (the standard route for a local app; this document does not say that every route below has been tried):

1. On a build machine, stage the artifacts: `ARTIFACT_BUNDLE_DIR=<bundle> ./build.sh`.
2. Copy this whole directory, including `artifacts/`, into a folder of its own in the
   Green's local apps folder (`config.yaml` directly inside it). How you reach that
   folder depends on how you connect:
   - the Samba share `local_apps` (Home Assistant versions from before the rename call the
     share `addons`), and the Terminal & SSH app's path `/local_apps` (older versions:
     `/addons`). These are the customer-visible routes;
   - on the host itself the same folder is `/mnt/data/supervisor/apps/local/<folder>`. That
     path is for engineering work only; an ordinary installation cannot reach it;
   - the `/addons/...` and `/apps/...` paths of the Supervisor API are web routes in a
     separate namespace and have nothing to do with these folders.

3. In Home Assistant open the app store, use **Check for updates** in its menu, and
   install the app from the local apps section. A build on the Home Assistant system takes
   several minutes.
4. Set the network passphrase (`wifi_passphrase`; there is no default), review the other options, start the
   app and open its panel. The form shows the passphrase field empty and required from
   first install. If you press Start before saving one, Home Assistant reports a
   missing-option error and the app does not start, so there is no status page to explain
   it.

## Supported hardware and compatibility details

- **Adapter identity.** The app and the bundled driver recognize the adapter by USB vendor ID `325b` and product ID `8100` only (the driver's module alias leaves class, subclass, and protocol open). A USB-A unit (`MM-U0-A-AU`) and a USB-C unit (`MM-U0-C-AU`) both present vendor `325b`, product `8100`, device version `0200`, and interface class `ff`, subclass `ff`, protocol `29` (the USB-A unit's descriptors were read on a Home Assistant Green: one interface, three endpoints, bound to `morse_usb`; the USB-C unit's identifiers were also read from a Windows device record, which does not show the interface count or endpoints). The USB-C unit was used on a Home Assistant Green through a USB-C-to-USB-A converter in earlier testing, where its board identifier resolved to board type `0807`; the exact final release candidate was smoke-tested with the USB-A unit. Another device with vendor `325b` and a different product ID is counted as unrecognized and, if it is the only candidate, produces the adapter-not-found state. A second recognized adapter stops the access point from starting.
- **Kernel guard.** The app accepts one exact Home Assistant OS build: the kernel release, the build string, the kernel configuration, and the host Wi-Fi module files must all match, and the bundled modules' version magic is checked. A rebuild with the same version number can therefore also be refused. Option validation runs before the guard, so a system with both an unsupported kernel and an invalid setting shows the invalid-setting message first. On an unsupported kernel the container and status page keep running and the access point stays off; before the guard fails, the manager may undo its own leftover changes from an earlier run.
- **Residue after stopping.** Loading the unsigned driver marks the host kernel as tainted, and the app writes a placeholder into the kernel's firmware search path. Neither is undone when the app stops; both clear when Home Assistant Green restarts. Stopping removes the firewall rules and network bridge the app added and unloads the driver.
- **Always-refused ports.** In addition to the pattern the Configuration page checks, the app refuses allowed-port entries for 22, 22222, 4357, and 62000 to 65500, entries outside 1 to 65535, upper-case or zero-padded forms, and more than 32 entries. These failures surface when the app starts, as an invalid-setting message.
- **SSID length.** The Configuration page counts characters; the app enforces the real 32-byte limit when it starts, so a name with multibyte characters can pass the form and fail at start.
- **Protected management frames.** The network requires WPA3-Personal (SAE) with protected management frames; there is no WPA2 or mixed mode.

## Upgrading saved settings

No action is needed for settings saved with no channel or with one of the listed channels;
they keep working. One exception is described below.

- If `channel` or `uplink_interface` was never saved (they were hidden "optional" form entries),
  Home Assistant fills in the defaults `auto` and empty, which behave exactly like the
  absent values did.
- This version uses one channel numbering for Australia: IEEE 802.11-2024. A channel
  number only has a meaning within one numbering, and the numbers of the earlier
  numbering (IEEE 802.11-2020) differ: for example `43` was a 1 MHz channel there and is
  an 8 MHz channel in IEEE 802.11-2024. Automatic mode (the default) is not affected. In manual mode the
  channel must match the selected bandwidth, so a channel saved under the earlier numbering may
  now be refused at start (the app shows "attention required" naming the channel
  option); choose a channel from the list for the bandwidth, or return to automatic mode.
- Exception: the form offers the Australian channels as a list, so a saved channel that is
  not one of them (for example `27` or `51`, which exist only in the earlier numbering) is
  refused by Home Assistant when you save or start, even in automatic mode (where the
  app itself would ignore it). Home Assistant checks before the app runs, so no
  status page can explain it: choose a listed channel, or `auto`.
- The options schema reaches an installed copy only when its version changes (a fresh
  install or an update to a higher version).
- The label "Radio mode" is now "Channel selection mode"; the option key is still
  `radio_mode` and its choices are still `automatic` and `manual`. The form order changed,
  and the option keys did not, so saved values keep their meaning.

## What is stored about devices

The DHCP server keeps its lease file in the app's private data folder, `/data/halow_leases`,
so an ordinary app restart does not forget which device holds which address; the server
reads the file when it starts and expires each lease by its own time (the app does not
extend, or expire, a lease itself). The file holds each client's MAC address, IP address,
lease expiry and DHCP client identifier. Client host names are not kept: the server is told
to ignore the names clients send, and the file is rewritten without names at every start.
At start the app also drops lines that are damaged, expired or outside the DHCP range;
a file that is oversized, unreadable or not a regular file is discarded, and a folder that
cannot be used makes the app fall back to a volatile file (leases then do not survive a
restart; a warning is logged). The lease folder (`/data/halow_leases`) is not included in Home Assistant backups
(`backup_exclude`) and it is deleted when the app is uninstalled. Stopping the app keeps the file. The
status information itself (`/run/halow/status.json`, which includes the addresses shown on
the page) is in memory only and is gone at every restart.

The status page, `status.json`, and the diagnostics view carry each station's MAC address and IP addresses, and the addresses of devices behind a bridged (WDS) station (at most 16 devices per station, 4 addresses per MAC). The app sends no reports of its own.

Logging. The DHCP server logs to the app log (it runs with `--no-daemon`). Run with its
defaults it would write every DHCP transaction there (DHCPDISCOVER, DHCPOFFER, DHCPREQUEST,
DHCPACK with the client's MAC and IP address); the configuration therefore says
`quiet-dhcp`, so routine DHCP transactions are not written to the app log. Errors and
important messages still are, and some of them name the client's MAC address (for example
"DHCPDISCOVER ... no address available" when the address pool is exhausted). The app's
own messages about the lease file give counts only, never addresses. This was checked with
the real dnsmasq in a container (with `quiet-dhcp` the routine transaction lines do not
appear; without it they do).

Host names. The DHCP server is told to ignore the host names clients send
(`dhcp-ignore-names`), so they are not stored. A consequence: a name a client supplies over
DHCP is not added to the gateway's DNS, so it cannot be resolved as a bare name through the
gateway. This is a deliberate privacy trade-off; removing the `dhcp-ignore-names` line in
`rootfs/usr/lib/halow/dnsmasq.sh` would let dnsmasq serve the names again while it runs (the
lease file is still rewritten without names at every start, so a name would then be
remembered only until the next restart). Hostapd's own log (`/run/halow/hostapd_s1g.log`,
in memory) records station MAC addresses for its connect events; whether any excerpt of it
reaches the app log in a failure message has not been checked here. dnsmasq runs as root inside the app container, as it did before the lease file
moved to `/data` (the move adds no new exposure of that kind); what it can reach is limited
by the app's AppArmor profile.

The status service accepts connections only from Home Assistant's Ingress proxy
(`172.30.32.2`) and drops every other peer, including this app's own processes on the
host network. The manager therefore never sends the status service a request. About every
30 seconds it checks, without opening a connection, that (1) s6 reports the service up and
the process is the status server running as its own unprivileged user; (2) the recorded
port is in the listening state on the bridge address in the kernel's TCP table; and (3) a
counter that the service rewrites about every 5 seconds from its accept loop, in a
directory only the service can write (`/run/halow-status`), has changed since the previous
check. Two failed checks in a row ask s6 to restart the service (a hung service is restarted about
60 to 90 seconds after it hangs, plus the restart itself); this never puts the app in the
attention state. Off-device checks back this: fakes, a real server process
and loopback sockets.

## Privileges and why

| Grant | Why |
|---|---|
| `kernel_modules` | Loads the radio driver modules (unsigned; they taint the host kernel). Mounts the host's `/lib/modules` read-only. |
| `SYS_ADMIN` | Only for mounts in the container's own mount namespace: the bind remount of the container's `/sys` around the write of the host firmware search path, the temporary mounts around each per-interface IPv6 setting, and the memory-backed (tmpfs) run directory `/run/halow`. |
| `NET_ADMIN` | The bridge, addresses, the firewall chains and NAT. |
| `NET_RAW` | DHCP and access-point packet sockets; listed so a Supervisor with reduced capabilities never drops it. |
| `host_network` | The adapter, bridge, DHCP and NAT live in the host's network namespace. |
| `host_dbus` | Gives the app the full system D-Bus. It is used only to ask NetworkManager to leave the radio and bridge interfaces alone, and to restore that afterwards. |
| `apparmor: true` | A shipped profile (`apparmor.txt`) instead of Docker's default. |
| `ingress` | The status page, on a Supervisor-assigned port. No other port is published. |

Not requested: `udev` (removed; nothing uses it), `full_access`, device or USB mappings,
Home Assistant or Supervisor API access, a watchdog. The status server runs as the
unprivileged user `halowstatus` with no capabilities and does not receive the Supervisor
token: before any service starts, a start-up script (`rootfs/etc/cont-init.d/`) makes the
directory where s6-overlay saves the container environment, token included, readable by
root only (if it cannot, s6-overlay stops the container before any service runs), and the
status launcher passes no token on. An image check run under the real s6-overlay start-up
(`tests/image_token_check.sh`, off-device) shows that the status user cannot read the
token while root services still can. Because of `host_network` that separation is defense
in depth, not isolation.

## Stopping: the time budgets

| Budget | Value | Set in |
|---|---|---|
| s6 service grace time: how long s6 waits for the services to stop (the manager's rollback runs here) | 90 s (`S6_SERVICES_GRACETIME=90000`) | `Dockerfile` |
| s6 kill grace time: after that, how long stragglers get before SIGKILL | 5 s (`S6_KILL_GRACETIME=5000`) | `Dockerfile` |
| the manager's `finish` time limit (a second, separate rollback pass) | 60 s; must stay below the service grace time | `rootfs/etc/services.d/manager/timeout-finish` |
| Supervisor stop timeout: after this the Supervisor kills the whole container | 120 s (`timeout: 120`) | `config.yaml` |

How they fit together: on stop, s6 sends the manager SIGTERM and the manager runs its
rollback. That first rollback has **no time limit of its own**. When the manager has
exited, s6 runs its `finish` hook, which repeats the rollback from the durable records and
is limited to 60 s. Both passes share the one 90 s service grace time: if the first pass
takes long, the `finish` pass gets less than its 60 s, and whatever is still running when
the 90 s are up is signalled and, 5 s later, killed. The Supervisor timeout (120 s) is
larger than the two s6 budgets together (95 s), so the Supervisor does not cut s6 off
first. A rollback cut off by SIGKILL leaves host changes behind; the next start finds and
removes them first. The values are engineering choices.

## Layout

```
config.yaml             app manifest (options schema, privileges)
translations/en.yaml    option names and descriptions shown in the form
apparmor.txt            AppArmor profile
Dockerfile, build.sh    image build; build.sh stages and verifies the bundled artifacts
MANIFEST.sha256         checksums of the bundled artifacts (re-checked at runtime too)
PROVENANCE.md, provenance.psv   source and license of every bundled artifact
SOURCE-OFFER.md, corresponding_source.psv, source_disposition.psv, source-offer/, source-assets/
                        how the corresponding source is provided, what it covers, the build scripts,
                        and the manifest of the release assets (the assets themselves are not in Git)
LICENSES/, third-party-notices/, THIRD-PARTY-NOTICES.md   license texts and notices copied into the image
tools/                  release gate, source-asset verification and publication check, SBOM, checklist
docs/LOCAL-IMAGE-BUILD.md   the local image build, verification and publication procedure
rootfs/etc/cont-init.d/ start-up hardening run as root before any service
rootfs/etc/services.d/  manager (host changes, supervision) and status (status page)
rootfs/usr/lib/halow/   libraries; status/ holds the status server
rootfs/usr/share/halow/ radio profile and compatibility tables
docs/ARCHITECTURE.md    module contracts
tests/                  off-device tests; tests/run_tests.sh runs them all
```

## Building and testing

Requires WSL2 or Linux with Docker (BuildKit with QEMU for ARM64) and the separately built
artifact bundle, whose directory is given in `ARTIFACT_BUNDLE_DIR` (`build.sh` has no
default).

```
tests/run_tests.sh                                      # all off-device tests
ARTIFACT_BUNDLE_DIR=<bundle> ./build.sh                 # stage + verify artifacts, print the pinned inputs
ARTIFACT_BUNDLE_DIR=<bundle> BUILD_IMAGE=1 ./build.sh   # ... and build morse-micro-halow-ap:local (linux/arm64)
tests/verify_image.sh                                   # inspect the built image
tools/check_reproducible_build.sh                       # optional: build twice and compare
```

`build.sh` refuses a Dockerfile whose base image is not pinned by digest or whose packages
are not pinned to exact versions, and records the base, the package pins and the artifact
manifest checksum as image labels.

`tools/check_reproducible_build.sh` builds the image twice without cache, with BuildKit's
reproducible timestamps, and compares the results. No result of it is recorded for this
version, so no claim is made that this build is reproducible; any comparison could in any
case hold only while the Alpine repository still serves the pinned versions.
