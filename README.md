# Morse Micro Wi-Fi HaLow Access Point for Home Assistant

This README documents version 1.0.0.

This Home Assistant app turns your Home Assistant Green into a Wi-Fi HaLow Access Point, using the [Morse Micro Wi-Fi HaLow USB Network Adapter](https://www.morsemicro.com/products/development-resources/wi-fi-halow-usb-network-adapters). Wi-Fi HaLow (IEEE 802.11ah) is sub-1 GHz Wi-Fi. Connected devices join their own separate network and reach your home network and the Internet through your Home Assistant Green.

Learn more about Wi-Fi HaLow at [Morse Micro](https://www.morsemicro.com/).

## Who This Is For

This project is for Home Assistant users who own a Home Assistant Green and a Morse Micro Wi-Fi HaLow USB Network Adapter, and who want to connect Wi-Fi HaLow devices to their home without adding a separate Access Point.

You should be comfortable installing a Home Assistant app, entering a network passphrase, and reading a status page. No command-line work is needed to use the app.

## Supported Scope

| Item | In this release |
|---|---|
| Home Assistant system | Home Assistant Green running Home Assistant OS 18.4 is supported in this release. Support for additional Home Assistant OS systems is planned for future releases. |
| Region | Australia is supported in this release. Support for additional regions is planned for future releases. |
| Adapter | One Morse Micro Wi-Fi HaLow USB Network Adapter. Both the USB-A and USB-C versions are supported. Connect one only; if two adapters are connected, the Access Point does not start. |
| Security | WPA3-Personal only. Devices that support only WPA2 cannot join. |

Anything not listed in this table is not supported in this release. "Planned for future releases" is an intention and not a commitment to a date or to any specific system or region.

## Status

Version 1.0.0 is the first release. Create a Home Assistant backup before you install or update. A backup of this app includes its settings, including the passphrase, so keep backups private. See [Supported Platforms and Known Limitations](docs/supported-platforms-and-known-limitations.md) for the supported scope and the known limitations.

## Quick Start

1. Add the Morse Micro Labs repository (`https://github.com/MorseMicroLabs/home-assistant-halow`) to the Home Assistant app store, then install the app.
2. On the Configuration page, enter a network passphrase. It is required and has no default.
3. Review the other settings, select Save, then select Start.
4. Select Open web UI on the app's Info page to see the status page.

The full steps are in [Installation and First Use](docs/installation-and-first-use.md).

## Documentation

| Guide | What it covers |
|---|---|
| [Installation and First Use](docs/installation-and-first-use.md) | Requirements, installing, first start, joining a device |
| [Configuration Guide](docs/configuration-guide.md) | Every setting, its default and valid values, and the Australian channel table |
| [Status Page Explanation](docs/status-page-explanation.md) | What each state, advisory, and error code means and what to do |
| [App Management](docs/update-and-uninstall.md) | Updating the app, updating Home Assistant OS, installing earlier versions, and removal |
| [Troubleshooting and Recovery](docs/troubleshooting-and-recovery.md) | Common problems and how to recover |
| [Security and Privacy](docs/security-and-privacy.md) | What the app can do on your system, what connected devices can reach, and how your data is handled |
| [Supported Platforms and Known Limitations](docs/supported-platforms-and-known-limitations.md) | Support matrix, known issues, and limitations |
| [Help and Support](docs/help-and-support.md) | How to get help and what to include |

## Getting Help

See [Help and Support](docs/help-and-support.md). Report problems and request features through [GitHub Issues](https://github.com/MorseMicroLabs/home-assistant-halow/issues). Do not report security vulnerabilities through public GitHub Issues; use the [Morse Micro security-disclosure form](https://www.morsemicro.com/policy/security-disclosure) (see [SECURITY.md](SECURITY.md)).

When you ask for help, include the error code shown on the status page and the diagnostics from the status page. The passphrase is removed from the diagnostics. Diagnostics include device addresses. Because GitHub Issues are public, remove or mask the MAC and IP addresses before you post them.

## License

The app's own source code, license texts, and notices are in the repository at [https://github.com/MorseMicroLabs/home-assistant-halow](https://github.com/MorseMicroLabs/home-assistant-halow).

- The original application code and its documentation are licensed under the Apache License 2.0 (see [LICENSE](LICENSE)).
- The kernel modules, including the Morse Micro driver, are licensed under GPL-2.0-only. They are separate from the application code.
- The adapter firmware and board data are provided under the Morse Micro Binary Distribution License Agreement. Other third-party components keep their own licenses.

See [NOTICE](NOTICE) for the license boundary and [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) for the components and their licenses as recorded.
