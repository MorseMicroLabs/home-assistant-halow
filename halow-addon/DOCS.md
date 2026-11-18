# Morse Micro Wi-Fi HaLow Access Point for Home Assistant

This app turns a Home Assistant Green into a Wi-Fi HaLow Access Point, using the Morse Micro Wi-Fi HaLow USB Network Adapter. Wi-Fi HaLow is the IEEE 802.11ah technology, sub-1 GHz Wi-Fi. Devices that connect join a private network and reach the home network and the Internet through the Home Assistant Green. No command-line work is needed.

## What You Need

| Requirement | Detail |
|---|---|
| Home Assistant system | Home Assistant Green running Home Assistant OS 18.4 is supported in this release. Support for additional Home Assistant OS systems is planned for future releases. |
| Adapter | One Morse Micro Wi-Fi HaLow USB Network Adapter. Both the USB-A and USB-C versions are supported. Connect one only; if two adapters are connected, the Access Point does not start. |
| Region | Australia is supported in this release. Support for additional regions is planned for future releases. |
| Devices | Devices must support WPA3. The network uses WPA3-Personal only, with no WPA2 or mixed mode. |
| Network | A network connection on the Home Assistant Green for reaching the network and the Internet. |

"Planned for future releases" is an intention and not a commitment to a date or to any specific system or region.

The app provides a Wi-Fi HaLow Access Point, WPA3-Personal security, automatic or manual channel selection with a bandwidth you choose, address assignment for connected devices, and a status page. It does not provide Home Assistant entities, notifications, or per-device controls.

## Install and First Use

1. Check that Home Assistant OS is version 18.4.
2. Create a Home Assistant backup. A backup of this app includes its settings, including the passphrase, so keep backups private.
3. Open the Home Assistant app store. On current versions, open Settings, then Apps, then App Store. Menu names can differ between Home Assistant versions.
4. Add the Morse Micro Labs repository: open the Repositories option (for example, from the menu at the top right of the app store), paste https://github.com/MorseMicroLabs/home-assistant-halow, and select Add.
5. Select Morse Micro Wi-Fi HaLow Access Point for Home Assistant, then select Install.
6. Plug the adapter into a USB port on the Home Assistant Green. If the adapter is not connected, the app keeps checking and starts the Access Point once it finds the adapter.
7. On the Configuration page, enter a network passphrase. It is required and has no default. Review the other settings.
8. Select Save, then select Start.
9. On the app's Info page, select Open web UI to see the status page. Turn on Show in sidebar to open it from the sidebar as Wi-Fi HaLow.

The app starts when Home Assistant starts. This can be disabled on the app's Info page.

To connect a device, choose the network name on the device and enter the passphrase. If the device cannot find the network on its own, set its frequency and bandwidth to those shown under "In use now" on the status page.

## Configuration

Changes take effect when the app is restarted.

| Setting | Default | Valid values and notes |
|---|---|---|
| Network name (SSID) | Wi-Fi-HaLow | Up to 32 characters; some symbols may reduce the maximum. Backslashes and line breaks are not accepted. The app enforces a 32-byte limit at start. |
| Network passphrase | none (required) | 12 to 63 standard keyboard characters. Included in Home Assistant backups. |
| Region | AU | AU. |
| Bandwidth (MHz) | 1 | 1, 2, 4, or 8. Chosen by you. |
| Channel selection mode | automatic | automatic or manual. Does not change the bandwidth. |
| Channel (manual mode only) | auto | In Automatic mode, this setting is ignored. In Manual mode, select a numeric channel that is valid for the chosen bandwidth; auto is not accepted. |
| Wi-Fi HaLow network address | 192.168.90.1/24 | The Access Point's address and the size of the private network. Must not overlap a network already in use. |
| First client address | 192.168.90.50 | Inside the network, different from the Access Point's address. |
| Last client address | 192.168.90.150 | Inside the network, after the first address. |
| Uplink interface | empty | Empty uses the interface associated with the default route. If default routes use more than one interface, the app cannot choose between them and shows UPLINK_UNAVAILABLE; enter the interface name here. Advanced: a physical network interface name such as `end0`. |
| Allowed ports | empty | Entries such as `tcp/1883` or `udp/5353`. Up to 32. Refused: 22, 22222, 4357, and 62000 to 65500. |

### Channels

Automatic selection chooses a channel each time the app starts. Manual mode always uses the Channel you set, and it must fit the bandwidth. These are the Australian channels (IEEE 802.11-2024 channel numbers):

| Bandwidth | Channels |
|---|---|
| 1 MHz | 28, 30, 32, 34, 36, 38, 40, 42, 44, 46, 48, 50 |
| 2 MHz | 29, 33, 37, 41, 45, 49 |
| 4 MHz | 31, 39, 47 |
| 8 MHz | 35, 43 |

If automatic selection does not complete, the Access Point starts on a backup channel for the chosen bandwidth, and the status page reports it. Restart the app to try again. In manual mode, a channel that does not fit the bandwidth stops the Access Point from starting, and the status page names the setting. Some devices need the frequency instead of the channel number. The status page shows both.

### Allowed Ports

By default, Wi-Fi HaLow devices can reach only DHCP, DNS, and ping on the Home Assistant Green.

**Warning.** Each entry you add makes a service reachable to every device on the Wi-Fi HaLow network, including services published by other apps. Add only services that are well understood and intended to be exposed.

## The Status Page

The status page is read-only and updates by itself about every 5 seconds.

| State | Meaning |
|---|---|
| Starting | The Access Point is starting. |
| Operating | The Access Point is running, and devices can connect. |
| Attention required | The page says what happened and what to do, and shows an error code. |

- **Wi-Fi HaLow radio.** "Your settings" shows what is saved. "In use now" shows the frequency, channel, bandwidth, who chose the channel (automatic selection, the manual setting, or a backup channel), and when it took effect.
- **Adapter and network.** Whether the adapter is Detected and whether Networking is Active.
- **Connected devices.** Devices that have joined since the app started, with Status (Online or Offline), Time, and IP address. Online and Offline show the connection to the Access Point, not whether a device is sending data.

### Error Codes

| Code | Meaning | Action |
|---|---|---|
| NO_ADAPTER | The adapter was not found. The app retries by itself. | Plug in the adapter. |
| MULTIPLE_ADAPTERS | More than one adapter is connected. The app retries by itself. | Leave one adapter connected. |
| UNSUPPORTED_KERNEL | The Home Assistant OS version is not supported by this app version. | Update the app, then restart it. The Access Point stays off until then. |
| REGION_UNVALIDATED | The selected region is not supported. | Choose a supported Region and restart the app. |
| CONFIG_INVALID | A setting has a value the app cannot use. | Change the setting named in the details, then restart the app. |
| FIRMWARE_INVALID | The adapter's firmware or driver files did not pass their check. | Update or reinstall the app, then restart it. |
| MODULE_LOAD_FAILED | The adapter's driver could not be loaded or started. | Restart the app. If it repeats, update the app. |
| HOST_STATE_FAILED | A system setting could not be checked or changed. | Restart the app. If the details mention IP forwarding, restart Home Assistant Green from the System page. |
| AP_START_FAILED | The Access Point could not start. The app retries a few times. | Check Region, Bandwidth, Channel selection mode, and Channel, then restart the app. |
| AP_DIED | The Access Point stopped unexpectedly. The app retries a few times. | Restart the app. |
| BACKEND_FAILED | The Wi-Fi HaLow network could not be set up or kept running. | Check that the Wi-Fi HaLow network address does not overlap another network, then restart the app. |
| NM_CHECK_FAILED | The app could not stop Home Assistant from managing the adapter and network. | Restart the app. If it repeats, restart Home Assistant Green from the System page, then update the app. |
| UPLINK_UNAVAILABLE | No network connection was found to reach the rest of the network. The app retries by itself. | Check the connection of the Home Assistant Green and the Uplink interface setting. |
| ROLLBACK_INCOMPLETE | The app could not confirm that it undid its changes. | Restart Home Assistant Green from the System page. This restarts the whole Home Assistant system. |
| STATUS_STALE | The status has not been updated recently. | Restart the app. If it stays, check the app's Log tab. |
| RADIO_MISMATCH | The Access Point is using radio settings that differ from those set. | Check the radio settings, then restart the app. |
| INTERNAL_ERROR | An unexpected problem. | Restart the app. If it repeats, update the app and keep the diagnostics for support. |
| RADIO_AUTO_FALLBACK (advisory) | Automatic selection did not complete, so a backup channel is in use. The Access Point is running. | Restart the app to try again, or choose manual mode and a channel. |

## App Management

- **Update the app.** Create a backup, update the app from the app store, then confirm that the status page shows Operating.
- **Update Home Assistant OS.** This release supports Home Assistant OS 18.4. The app includes a driver matched to the Home Assistant OS build, so some OS updates may require a compatible app update. Before updating Home Assistant OS, check that a compatible app version is available. If the installed version is not supported, the Access Point stays off, and the app does not apply new radio or network changes. To recover, update the app to a compatible version, then restart it.
- **Install an earlier version.** The app has no rollback button. Restore the backup made before the update, or install the earlier app version again if it is offered. Earlier versions are not guaranteed to stay available.
- **Stop.** Stopping the app disconnects all devices, removes the firewall rules and network bridge that the app added, and unloads the radio driver.
- **Uninstall.** Uninstalling removes the app, its container and image, and its stored data, including the record of which device holds which address. Backups made earlier still contain the settings and the passphrase. Restart Home Assistant Green after removing the app to clear the remaining temporary driver and firmware-search state.

## Troubleshooting

Start with the status page, and follow its "What to do" text.

| Problem | What to do |
|---|---|
| Nothing happens after Start | Open the status page. If the app was started without saving a passphrase, Home Assistant reports a missing-option error: set a passphrase, save, then start. |
| The adapter is not found | Plug in the adapter. The app keeps checking. |
| A device cannot find the network | Set it to the frequency and bandwidth under "In use now", and check that it supports WPA3. |
| A device joins but has no access | Check that the Home Assistant Green is connected to the local network and that the Uplink interface is correct or empty. |
| Home Assistant does not find the devices | The Wi-Fi HaLow network is separate. Add devices by IP address where an integration offers it. |
| Home Assistant refuses a channel | Pick a channel from the list, or auto. |
| The Configuration page shows an old value | After settings are saved, Home Assistant may keep showing the earlier values. Reload the page (Ctrl+F5, or pull down to refresh in the Companion app) before changing anything else, then check the status page. |
| The restart prompt was declined | The Access Point keeps the previous settings until the app is restarted. |

Recovery order: restart the app, check settings, update the app, restart Home Assistant Green when the status page recommends it, reinstall the app, then contact support.

To get help or report a problem, open an issue at [GitHub Issues](https://github.com/MorseMicroLabs/home-assistant-halow/issues). GitHub Issues are public, so remove or mask device MAC and IP addresses from diagnostics before posting them. Do not report security vulnerabilities through public GitHub Issues; use the [Morse Micro security-disclosure form](https://www.morsemicro.com/policy/security-disclosure).

## Security and Privacy

This section describes the design and observed behavior. It is not a security assessment or a guarantee.

- The network uses WPA3-Personal only, with protected management frames. Anyone with the passphrase can join.
- Devices are isolated from each other, so they cannot discover each other.
- Devices can reach the local network and the Internet through the Home Assistant Green, including the router's admin page. The app does not currently offer a way to restrict this.
- Devices cannot reach services on the Home Assistant Green except DHCP, DNS, and ping, unless the port is listed under Allowed ports.
- Devices on the local network cannot start connections to Wi-Fi HaLow devices. Home Assistant itself and apps on the system can.
- Wi-Fi HaLow devices have no IPv6.
- The app needs elevated access to load a radio driver and set up networking: kernel modules, limited system administration, network administration, raw network access, the host network, and the system message bus. The radio driver is built for this system and is not signed by the operating system vendor. Loading it sets the kernel's taint marker, a standard flag that records that an out-of-tree driver was loaded. This is expected and does not, by itself, mean something has failed. The app also adds a temporary entry to the system's firmware search path so the driver can find the adapter's firmware. Both the marker and the entry clear when Home Assistant Green is restarted.
- The app accepts one exact Home Assistant OS build.
- A Home Assistant backup of this app includes the passphrase. Keep backups private.
- Anyone who can open the app's panel can see the MAC and IP addresses of connected devices on the status page and in the diagnostics. The diagnostics have the passphrase removed but include device addresses. Check them before sharing them.
- Hostnames that devices send are not stored. The app does not send reports of its own.

## Known Limitations

- If Home Assistant OS is updated to a version this app does not support, the Access Point stays off until the app is updated to a compatible version.
- The app provides no Home Assistant entities, notifications, or per-device controls.
- The client address range limits the number of devices.

## License and Source

Source code and license information is in the repository at [https://github.com/MorseMicroLabs/home-assistant-halow](https://github.com/MorseMicroLabs/home-assistant-halow).

- The original application code and its documentation are licensed under the Apache License 2.0.
- The kernel modules, including the Morse Micro driver, are licensed under GPL-2.0-only. They are separate from the application: the kernel loads them as separate files, and the application code is not part of them.
- Firmware, board data, and other third-party components, such as the base image, the Wi-Fi Access Point software, and system libraries, keep their own licenses. They are listed in the repository's notices.
