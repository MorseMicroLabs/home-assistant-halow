# Changelog

Changes in each version, newest first.

## [1.0.0] - first release

Version 1.0.0 is the first release of the Morse Micro Wi-Fi HaLow Access Point for Home Assistant.

### What This Version Includes

- Home Assistant app software that turns a Home Assistant Green into a Wi-Fi HaLow Access Point,
  using the Morse Micro Wi-Fi HaLow USB Network Adapter. Devices that connect join their own
  separate network and reach the home network and the Internet through the Home Assistant Green.
- Support for Home Assistant Green running Home Assistant OS 18.4 in this release. Support for
  additional Home Assistant OS systems is planned for future releases. Check that a compatible
  app version is available before you update Home Assistant OS.
- Support for Australia in this release. Support for additional regions is planned for future
  releases.
- Support for one Morse Micro Wi-Fi HaLow USB Network Adapter, in the USB-A and USB-C versions.
  Connect one only.
- WPA3-Personal security.
- A Configuration page to configure the app. Channel selection mode (automatic or manual) is
  separate from Bandwidth (1, 2, 4, or 8 MHz), which is chosen by the user.
- A default network name of Wi-Fi-HaLow, which can be changed.
- A status page that shows settings, current usage, the adapter and network state, connected
  devices, and any attention messages.
- License: the application code is licensed under the Apache License 2.0. The Morse Micro
  driver modules the app loads remain under GPL-2.0-only, and other components keep their
  own licenses.

### Security Notes

- The network uses WPA3-Personal only. Any device with the passphrase can join.
- The app needs elevated access to the Home Assistant system to load its radio driver and set
  up networking.
- Each entry under Allowed ports makes a service reachable to every device on the Wi-Fi HaLow
  network. Add only services that are well understood and intended to be exposed.
- Diagnostics for support have the passphrase removed but include device addresses. Check them
  before sharing them.

### Known Issues

- After settings are saved, Home Assistant may keep showing the earlier values on the
  Configuration page. Reload the page (Ctrl+F5, or pull down to refresh in the Companion
  app) before changing anything else. The status page always shows what is in use.

### Limitations

- If Home Assistant OS is updated to a version this app does not support, the Access Point
  stays off until the app is updated to a compatible version.
- The app provides no Home Assistant entities, notifications, or per-device controls.
- Wi-Fi HaLow devices can reach the local network and the Internet through the Home Assistant
  Green. The app does not currently offer a way to restrict this.
- Wi-Fi HaLow devices have no IPv6, and Home Assistant may not discover them automatically.
- The client address range limits the number of devices.

### Upgrade Notes

- This is the first release, so there is no earlier version to upgrade from.
- Create a Home Assistant backup before installing or updating. A backup of this app includes
  its settings, including the passphrase, so keep backups private.
