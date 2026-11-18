# Supported Platforms and Known Limitations

This guide states what this release supports, what is planned, what is not supported, and what is known to be limited.

## Support Matrix

Home Assistant Green running Home Assistant OS 18.4 is supported in this release. Support for additional Home Assistant OS systems is planned for future releases.

Australia is supported in this release. Support for additional regions is planned for future releases.

"Planned for future releases" describes an intention. It is not a commitment to a date or to any specific system or region.

| Area | Supported in this release | Planned for future releases | Not supported |
|---|---|---|---|
| Home Assistant system | Home Assistant Green | Additional Home Assistant OS systems | Any other system in this release |
| Home Assistant OS version | 18.4 | Additional Home Assistant OS systems | Other versions, including earlier and later builds, until a compatible app version is available |
| Region | Australia (`AU`) | Additional regions | Any other region in this release |
| Adapter | One Morse Micro Wi-Fi HaLow USB Network Adapter (USB-A and USB-C versions; connect one only) | | Two or more adapters at once (the Access Point does not start) |
| Security | WPA3-Personal | | WPA2 and mixed mode |
| Addressing | IPv4 | | IPv6 on the Wi-Fi HaLow network |
| Bandwidth | 1, 2, 4, and 8 MHz | | Other widths |
| Home Assistant integration | The app and its status page | | Home Assistant entities, notifications, and per-device controls |

## Known Issues

- After you save settings, Home Assistant may keep showing the earlier values on the Configuration page. Reload the page (Ctrl+F5, or pull down to refresh in the Companion app) before changing anything else. The status page always shows what is in use.
- If you update Home Assistant OS to a version this app does not support, the Access Point stays off until you update the app to a compatible version.
- The app provides no Home Assistant entities, notifications, or per-device controls.

## Limitations

- **Home Assistant OS updates.** The app includes a driver matched to one exact Home Assistant OS build. Check that a compatible app version is available before you update Home Assistant OS.
- **One adapter.** If two adapters are connected, the Access Point does not start.
- **WPA3 only.** Devices that support only WPA2 cannot join.
- **Device limit.** The number of devices is limited by the client address range.
- **No IPv6.** Wi-Fi HaLow devices have no IPv6.
- **Discovery.** Home Assistant may not discover Wi-Fi HaLow devices automatically, because the Wi-Fi HaLow network is separate. Adding devices by IP address may work where an integration offers it.
- **Local network access.** Wi-Fi HaLow devices can reach your local network and the Internet through your Home Assistant Green, including your router's admin page. The app does not currently offer a way to restrict this.
- **One-way connections.** Devices on your local network cannot start connections to Wi-Fi HaLow devices. Home Assistant itself and apps on your system can.
- **Hostnames.** Hostnames that devices send are not stored, so a bare device name does not resolve through the Access Point.
- **Restart after removal.** Some temporary host-level state remains after you stop or remove the app. Restart Home Assistant Green to clear it. See [Security and Privacy](security-and-privacy.md).
- **Settings take effect on restart.** The status page always shows what is in use.

## Where to Look for Future Support Changes

Check the release notes and the app's changelog for changes to supported systems and regions. They are in the repository at `https://github.com/MorseMicroLabs/home-assistant-halow`.
