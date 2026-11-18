# Configuration Guide

This guide describes every setting on the app's Configuration page. The settings appear in this order: network, radio, client addressing, then advanced networking. Home Assistant shows the labels below exactly as written here.

Changes take effect when you restart the app. The status page always shows what is in use.

## Settings at a Glance

| Setting | Default | Valid values |
|---|---|---|
| Network name (SSID) | `Wi-Fi-HaLow` | 1 to 32 characters (see below) |
| Network passphrase | none (required) | 12 to 63 standard keyboard characters |
| Region | `AU` | `AU` |
| Bandwidth (MHz) | `1` | `1`, `2`, `4`, or `8` |
| Channel selection mode | `automatic` | `automatic` or `manual` |
| Channel (manual mode only) | `auto` | In Automatic mode, this setting is ignored. In Manual mode, select a numeric channel that is valid for the chosen bandwidth; `auto` is not accepted. |
| Wi-Fi HaLow network address | `192.168.90.1/24` | An IPv4 address with a prefix length |
| First client address | `192.168.90.50` | An IPv4 address inside the network |
| Last client address | `192.168.90.150` | An IPv4 address inside the network, after the first |
| Uplink interface | empty | Empty uses the interface associated with the default route. If default routes use more than one interface, the app cannot choose between them and shows `UPLINK_UNAVAILABLE`; enter the interface name here. Advanced: a physical network interface name such as `end0`. |
| Allowed ports | empty | Entries such as `tcp/1883` or `udp/5353` |

## Network

### Network name (SSID)

The name your devices look for. The default is `Wi-Fi-HaLow`, and you can change it.

- Up to 32 characters. Some symbols use more than one character of space, which can reduce the maximum.
- Backslashes and line breaks are not accepted.
- The Configuration page counts characters, but the app enforces a limit of 32 bytes when it starts. A name with accented letters or other multibyte characters can pass the page and still be refused at start. If that happens, the status page shows `CONFIG_INVALID` and names this setting. Shorten the name and restart the app.

### Network passphrase

The WPA3 passphrase for the network. It is required and has no default.

- 12 to 63 characters, using only standard keyboard characters (no accented letters or emoji).
- The app does not start until you set one. If you select Start before saving a passphrase, Home Assistant reports a missing-option error, and there is no status page to explain it.
- Every device on the network uses this same passphrase.
- It is included in Home Assistant backups, so keep backups private.

## Radio

### Region

The country whose radio rules apply. The default is `AU`. Australia is supported in this release. Support for additional regions is planned for future releases.

### Bandwidth (MHz)

The channel width in MHz: `1`, `2`, `4`, or `8`. The default is `1`. You always choose it, and the app never changes it. In manual mode, the channel must match the bandwidth.

### Channel selection mode

How the channel is chosen. This setting does not change the bandwidth.

- **Automatic** (the default): the app picks a channel each time it starts.
- **Manual**: the app always uses the channel set in Channel (manual mode only).

### Channel (manual mode only)

The channel to use in manual mode. The default is `auto`, which means no channel is chosen. In Automatic mode, this setting is ignored. In Manual mode, select a numeric channel that is valid for the chosen bandwidth; `auto` is not accepted.

In manual mode, the channel must fit the bandwidth. Check it whenever you change the bandwidth.

## How Bandwidth, Channel Selection Mode, and Channel Work Together

Bandwidth is the width of the channel, and you always choose it. Channel selection mode decides how the channel is picked. Channel is used only when the mode is manual.

| Mode | Bandwidth | Channel | Result |
|---|---|---|---|
| Automatic | Your choice | Ignored (leave on `auto`) | The app picks a channel for your bandwidth each time it starts. |
| Manual | Your choice | A channel that fits the bandwidth | The app always uses that channel. |
| Manual | Your choice | `auto`, or a channel that does not fit the bandwidth | The Access Point does not start. The status page shows `CONFIG_INVALID` and names the setting. |

If automatic selection does not complete, the Access Point starts on a backup channel for your bandwidth, and the status page says so with an advisory titled "Using a backup channel". Restart the app to try automatic selection again, or set Channel selection mode to manual and choose a channel.

Home Assistant only offers channels 28 to 50 and `auto` in the Channel list. It refuses any other value when you save, even in automatic mode. If it refuses, pick a channel from the list, or `auto`.

### Australian Channel Table

In manual mode, choose a channel from the row for your bandwidth (Australia, IEEE 802.11-2024 channel numbers).

| Bandwidth | Channels |
|---|---|
| 1 MHz | 28, 30, 32, 34, 36, 38, 40, 42, 44, 46, 48, 50 |
| 2 MHz | 29, 33, 37, 41, 45, 49 |
| 4 MHz | 31, 39, 47 |
| 8 MHz | 35, 43 |

A channel number has a meaning only within one numbering. The same number can refer to a different bandwidth in other numbering schemes, so use the table above.

Some devices need the frequency instead of the channel number. The status page shows both under "In use now".

## Client Addressing

### Wi-Fi HaLow network address

The Access Point's own address and the size of the private network, for example `192.168.90.1/24`. The default is `192.168.90.1/24`. It must not overlap a network you already use. If it does, the status page shows `CONFIG_INVALID` or `BACKEND_FAILED`.

### First client address and Last client address

The range of addresses given to your devices. The defaults are `192.168.90.50` and `192.168.90.150`.

- Both addresses must be inside the network above.
- The first address must be different from the Access Point's own address.
- The last address must come after the first address.
- The number of devices that can connect is limited by this range.

## Advanced Networking

### Uplink interface

The network interface your Wi-Fi HaLow devices use to reach your network and the Internet. The default is empty, which uses the interface associated with the default route. If default routes use more than one interface, the app cannot choose between them and shows `UPLINK_UNAVAILABLE`; enter the interface name here.

Advanced: enter a physical network interface name such as `end0`. Names of container, virtual, or Wi-Fi HaLow interfaces are refused.

Home Assistant may mark this field as required even though it can be empty. Leave it empty unless you need to name a connection.

If the interface associated with the default route changes while the app runs, the Access Point restarts and devices reconnect.

### Allowed ports

Leave this empty unless you need it. It lets Wi-Fi HaLow devices reach a service on your Home Assistant Green. Write each entry as `tcp/1883` or `udp/5353` (lower case).

- Each entry is a protocol (`tcp` or `udp`), a slash, and a port from 1 to 65535, with no leading zeros.
- You can add up to 32 entries.
- The app refuses some ports because they are reserved for system management: 22, 22222, 4357, and 62000 to 65500. A refused entry shows `CONFIG_INVALID` when the app starts.
- Without entries, devices reach only DHCP (address assignment), DNS (name lookup), and ping on your Home Assistant Green.

**Warning.** Each entry makes a service reachable to every device on the Wi-Fi HaLow network, including services published by other apps. Add only services you understand and intend to expose.

## Configuration Examples

**Keep the defaults and choose a channel automatically.** Set a passphrase, leave everything else unchanged, and start the app.

**Use a fixed channel.** Set Bandwidth (MHz) to `8`, Channel selection mode to `manual`, and Channel (manual mode only) to `35` or `43`. Save, then restart the app.

**Let a device reach an MQTT broker on your Home Assistant Green.** Add `tcp/1883` to Allowed ports. Read the warning above first.

## If a Setting Is Refused

When a setting has a value the app cannot use, the status page shows `CONFIG_INVALID` with the setting named in the details. Change that setting to a valid value, then restart the app. If the setting is refused by Home Assistant itself (for example a channel outside the list), Home Assistant shows the message on the Configuration page.
