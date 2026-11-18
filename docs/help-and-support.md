# Help and Support

This guide explains how to get help with the Morse Micro Wi-Fi HaLow Access Point for Home Assistant, what to include in a request, and what the diagnostics contain.

## Before You Ask for Help

1. Open the status page and read the message. Most conditions say what to do.
2. Look up the error code in the [Status Page Explanation](status-page-explanation.md).
3. Work through [Troubleshooting and Recovery](troubleshooting-and-recovery.md).
4. Check [Supported Platforms and Known Limitations](supported-platforms-and-known-limitations.md) to confirm that your system, region, and adapter are supported.

## How to Get Help

Report problems and request features through GitHub Issues in the repository: https://github.com/MorseMicroLabs/home-assistant-halow/issues

Do not report security vulnerabilities through public GitHub Issues. Report a suspected vulnerability through the [Morse Micro security-disclosure form](https://www.morsemicro.com/policy/security-disclosure). See [Security and Privacy](security-and-privacy.md).

Learn more about Wi-Fi HaLow at [Morse Micro](https://www.morsemicro.com/).

## What to Include in a Request

Include as much of this as you can:

- **The error code** shown on the status page, and the text of the message.
- **The app version** (`1.0.0`) and your **Home Assistant OS version**.
- **Your system**: Home Assistant Green, and which adapter you use (USB-A or USB-C).
- **Your settings**, except the passphrase: region, bandwidth, channel selection mode, channel, and any value you changed from the default.
- **What you did** just before the problem, and whether it happens every time.
- **What you expected** and what happened instead.
- **The diagnostics** from the status page, after you have checked them (see below).
- **The app's Log tab** text, if the status page asks you to check it. Remove anything you do not want to share.

Do not include your passphrase. Support does not need it.

## What the Diagnostics Contain

The footer of the status page links to "Diagnostics for support". The report is labeled "passphrase removed; includes device addresses". It contains:

- The same status information as the page: your settings, what is in use, the adapter and network state.
- The MAC and IP addresses of connected devices, and of devices behind a bridging device.
- Technical detail about the system compatibility check.
- A short, redacted tail of recent app messages.

The passphrase is removed from the report. Read it before you share it. Diagnostics include device addresses. Because GitHub Issues are public, remove or mask the MAC and IP addresses before you post them.

The diagnostics are not sent anywhere automatically. The app does not send reports of its own.

## What Support Can and Cannot Do

Support can help you interpret status messages, check your settings, and work out whether a problem comes from the app, the adapter, your devices, or your network.

For this release:

- Only Home Assistant Green running Home Assistant OS 18.4 in Australia is supported.
- Other systems and regions are planned for future releases and are not supported now.
- Some error conditions are uncommon, so a described fix may not apply to your situation.

## Giving Feedback

Send feedback and feature requests through the same route as problem reports.

## Security Issues

If you believe you found a security issue, do not post it publicly. See the reporting section of [Security and Privacy](security-and-privacy.md).
