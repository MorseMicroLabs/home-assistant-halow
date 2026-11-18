# Morse Micro Wi-Fi HaLow Access Point for Home Assistant

Version `1.0.0`, the first release.

This Home Assistant app turns your Home Assistant Green into a Wi-Fi HaLow access point, using the [Morse Micro Wi-Fi HaLow USB Network Adapter](https://www.morsemicro.com/products/development-resources/wi-fi-halow-usb-network-adapters). Wi-Fi HaLow (IEEE 802.11ah) is sub-1 GHz Wi-Fi. Connected devices join their own separate network and reach your home network and the internet through your Home Assistant Green.

Learn more about Wi-Fi HaLow at [Morse Micro](https://www.morsemicro.com/).

## What You Need

- **Home Assistant Green** running Home Assistant OS 18.4 is supported in this release. Support for additional Home Assistant OS systems is planned for future releases. See "Home Assistant OS Updates" below.
- **One Morse Micro Wi-Fi HaLow USB Network Adapter.** The USB-A and USB-C versions are both supported. Connect one only; if two adapters are connected, the access point does not start.
- **Region.** Australia is supported in this release. Support for additional regions is planned for future releases.
- **Devices that support WPA3.** The network uses WPA3-Personal only, with no WPA2 or mixed mode, so devices that support only WPA2 cannot join.

## Home Assistant OS Updates

This release supports Home Assistant OS 18.4. Because the app includes a driver matched to Home Assistant OS, some OS updates may require a compatible app update. Before updating Home Assistant OS, check that a compatible app version is available.

If the installed version is not supported, the Wi-Fi HaLow access point stays off, and the app does not apply new radio or network changes. The status page explains what to do. To recover, update the app to a compatible version, then restart it.

## Set Up

1. Install the app from the app store. Home Assistant downloads the app image during installation and updates, so your Home Assistant Green needs internet access.
2. On the Configuration page, enter a network passphrase. It is required and has no default.
3. Review the other settings, select Save, then select Start.
4. Select Open web UI on the app's Info page to see the status page. Turn on Show in sidebar to open it from the sidebar as Wi-Fi HaLow.

The app starts when Home Assistant starts. You can switch that off on the app's Info page.

## Settings

| Setting | Default | What it does |
|---|---|---|
| Network name (SSID) | `Wi-Fi-HaLow` | The name your devices look for. Up to 32 characters; some symbols may reduce the maximum. Backslashes and line breaks are not accepted. |
| Network passphrase | none (required) | The WPA3 passphrase, 12 to 63 characters, using only standard keyboard characters. |
| Region | `AU` | The country whose radio rules apply. Australia is supported in this release. |
| Bandwidth (MHz) | `1` | The channel width: 1, 2, 4, or 8 MHz. You always choose it. |
| Channel selection mode | `automatic` | How the channel is chosen. This does not change the bandwidth. |
| Channel (manual mode only) | `auto` | In Automatic mode, this setting is ignored. In Manual mode, select a numeric channel that is valid for the chosen bandwidth; `auto` is not accepted. |
| Wi-Fi HaLow network address | `192.168.90.1/24` | The access point's address and the size of the private network. |
| First client address, Last client address | `.50` to `.150` | The range of addresses given to devices. |
| Uplink interface | empty | The network interface your devices use to reach your network. Empty uses the interface associated with the default route. If default routes use more than one interface, the app cannot choose between them and shows `UPLINK_UNAVAILABLE`; enter the interface name here. Advanced: a physical network interface name such as `end0`. |
| Allowed ports | empty | Services on your Home Assistant Green that Wi-Fi HaLow devices may reach, for example `tcp/1883`. Leave empty unless you need it. |

**Bandwidth, channel selection mode, and channel.** Bandwidth is the width of the channel, and you always choose it. Channel selection mode decides how the channel is picked: Automatic chooses a channel each time the app starts, and Manual always uses the Channel you set. In manual mode the channel must fit the bandwidth (Australia, IEEE 802.11-2024 channel numbers):

| Bandwidth | Channels |
|---|---|
| 1 MHz | 28, 30, 32, 34, 36, 38, 40, 42, 44, 46, 48, 50 |
| 2 MHz | 29, 33, 37, 41, 45, 49 |
| 4 MHz | 31, 39, 47 |
| 8 MHz | 35, 43 |

If automatic selection does not complete, the access point starts on a backup channel for your bandwidth and the status page says so. Restart the app to try again. In manual mode, a channel that does not fit the bandwidth stops the access point from starting, and the status page names the setting. Some devices need the frequency instead of the channel number. The status page shows both.

Changes take effect when you restart the app. The status page always shows what is in use.

**Allowed ports.** By default, Wi-Fi HaLow devices can reach only DHCP (address assignment), DNS (name lookup), and ping on your Home Assistant Green. Each entry you add makes a service reachable to every device on the Wi-Fi HaLow network, including services published by other apps. Add only services you understand and intend to expose.

## The Status Page

The status page shows whether the access point is starting, is operating, or needs attention. When attention is needed, it says what happened and what to do, with an error code to quote if you contact support. It also shows:

- **Your settings:** region, channel selection mode, bandwidth, and channel as saved.
- **In use now:** the frequency, channel, and bandwidth the access point is using, and whether the channel was chosen automatically, by your manual setting, or as a backup.
- **Adapter and network:** whether the adapter is detected and the network is active.
- **Connected devices:** the devices that have joined since the app started, with their status and IP addresses.

The page is read-only. Anyone who can open the app's panel can see the MAC and IP addresses of connected devices, on the page and in the diagnostics for support. The diagnostics have the passphrase removed but include device addresses, so check them before you share them.

## What Wi-Fi HaLow Devices Can Reach

- Devices are isolated from each other, so they cannot discover each other.
- Devices can reach your local network and the internet through your Home Assistant Green, including other devices on your network and your router's admin page. The app does not currently offer a way to restrict this.
- Devices cannot reach services on your Home Assistant Green except DHCP, DNS, and ping, unless you list the port under Allowed ports.
- Devices on your local network cannot start connections to Wi-Fi HaLow devices. Home Assistant itself and apps on your system can.
- Wi-Fi HaLow devices have no IPv6.
- Home Assistant may not discover Wi-Fi HaLow devices automatically, because the Wi-Fi HaLow network is separate. Adding devices by IP address may work where an integration offers it.

## Backups and Your Passphrase

A Home Assistant backup of this app includes its settings, including the passphrase, so keep your backups private. The record of which device holds which address is not included in backups. After a restore, devices ask for their addresses again.

## Troubleshooting

- **Nothing seems to happen after you select Start.** Open the status page (Open web UI) first. It says whether the access point is starting, running, or needs attention.
- **Attention required.** Follow the "What to do" text on the status page.
- **The adapter is not found.** Plug the adapter into your Home Assistant Green. The app keeps checking and starts the access point automatically.
- **The Configuration page shows an old value after you saved.** Reload the page (Ctrl+F5, or pull down to refresh in the Companion app) before changing anything else, and check the status page for what is in use.
- **You declined the restart prompt.** The access point keeps running the previous settings until you restart the app.
- **Home Assistant refuses to save a channel.** Pick a channel from the list, or `auto`.
- **A device cannot find the network.** Set it to the frequency and bandwidth under "In use now", and make sure it supports WPA3.
- **The app could not confirm that it undid its changes.** The status page recommends restarting Home Assistant Green from the System page. This restarts your whole Home Assistant system.

## Good to Know

- Stopping the app disconnects all devices. The firewall rules and network bridge that the app added are removed, and the radio driver is unloaded. Restart Home Assistant Green after removing the app to clear the remaining temporary driver state.
- If the interface associated with the default route changes while the app runs, the access point restarts and devices reconnect.
- The number of devices is limited by the client address range.
- The app provides no Home Assistant entities, notifications, or per-device controls.
- Host names that devices send are not stored.
- The app does not send reports of its own. Traffic from Wi-Fi HaLow devices leaves your Home Assistant Green like any other traffic on your network.

## Help and Support

Report problems and request features through [GitHub Issues](https://github.com/MorseMicroLabs/home-assistant-halow/issues). GitHub Issues are public, so remove or mask device MAC and IP addresses from diagnostics before posting them. Do not report security vulnerabilities through public GitHub Issues; use the [Morse Micro security-disclosure form](https://www.morsemicro.com/policy/security-disclosure).

## License

The source code of the GPL and LGPL components is provided with each release, as release assets of this repository.

The application code is licensed under the Apache License 2.0. The Morse Micro driver modules that the app loads are licensed under GPL-2.0-only and are separate from the application code. The adapter firmware and board data are provided under the Morse Micro Binary Distribution License Agreement, and other components keep their own licenses. See [LICENSE](LICENSE), [NOTICE](NOTICE), and [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
