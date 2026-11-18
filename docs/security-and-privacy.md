# Security and Privacy

This guide describes what the app can do on your system, what connected Wi-Fi HaLow devices can reach, and how your passphrase and device information are handled. It describes the design and the behavior that has been observed. It is not a security assessment and not a guarantee.

## Summary

- The network uses WPA3-Personal only, with protected management frames. There is no WPA2 or mixed mode.
- One shared passphrase protects the network. Anyone who has it can join.
- Connected devices are isolated from each other, but they can reach your home network and the Internet through your Home Assistant Green.
- Devices cannot reach services on your Home Assistant Green except DHCP, DNS, and ping, unless you list the port under Allowed ports.
- The app needs broad access to your Home Assistant system to load a radio driver and set up networking. Install it only on a system where you accept that.
- A Home Assistant backup of this app includes the passphrase.

## Why the App Needs Elevated Access

The app turns your Home Assistant Green into an Access Point. That requires changes to the system that an ordinary app does not make. The access it requests is listed here in plain terms.

| Access the app requests | What it is used for |
|---|---|
| Kernel modules | Loads the radio driver for the adapter. The driver is built for this system and is not signed by the operating system vendor. Loading it sets the kernel's taint marker, a standard flag that records that an out-of-tree driver was loaded. This is expected, does not by itself mean that something has failed, and clears when you restart Home Assistant Green. |
| System administration (limited use) | Used only for a few mounts inside the app's own container: writing a temporary entry into the system's firmware search path so the driver can find the adapter's firmware (the entry points to nothing after the app stops and clears when you restart Home Assistant Green), and a memory-backed folder where the generated radio configuration (which contains the passphrase) is kept while the app runs. |
| Network administration | Creates the private Wi-Fi HaLow network: the network bridge, addresses, firewall rules, and routing to your network. |
| Raw network access | Lets the address-assignment service and the Access Point use the network packets they need. |
| Host network | The adapter, the bridge, address assignment, and routing live in the network of your Home Assistant system, not in an isolated app network. |
| System message bus (D-Bus) | Gives the app the full system message bus. The app uses it only to ask NetworkManager to leave the radio and bridge interfaces alone, and to restore that afterward. |
| AppArmor profile | The app ships a profile intended to limit what the app can do. |
| Ingress | Shows the status page inside Home Assistant. The app publishes no other port. |

The app does not request full access to the system, USB or device mappings, or access to the Home Assistant or Supervisor interfaces. The status page runs as an unprivileged user and is not given the Supervisor token. Because the app uses the host network, this separation adds a layer of protection but does not isolate the status page completely.

The AppArmor profile is intended to limit what the app can do. Do not rely on it as your only protection.

## The Radio Driver and the Exact Kernel Match

The radio driver files in the app are not signed. They are built for one exact Home Assistant OS build. Before the app makes any change to your system, it checks that your Home Assistant OS build matches: the kernel release, the build string, the kernel configuration, and the system's Wi-Fi module files must all match, and the driver's version must match. If anything differs or cannot be read, the app refuses to start the Access Point and shows `UNSUPPORTED_KERNEL`.

This is why some Home Assistant OS updates need a matching app update first. See [App Management](update-and-uninstall.md).

Because the driver is not signed, you are trusting the app package you install. Install the app only from the Morse Micro Labs repository (`https://github.com/MorseMicroLabs/home-assistant-halow`).

## What Connected Devices Can Reach

| Destination | Can a Wi-Fi HaLow device reach it? |
|---|---|
| Other Wi-Fi HaLow devices | No. Devices are isolated from each other, so they cannot discover each other. |
| The Internet, through your Home Assistant Green | Yes. |
| Your local network, including other devices and your router's admin page | Yes, by design. The app does not currently offer a way to restrict this. |
| DHCP, DNS, and ping on your Home Assistant Green | Yes. |
| Other services on your Home Assistant Green | No, unless you list the port under Allowed ports. |
| IPv6 | No. Wi-Fi HaLow devices have no IPv6. |

In the other direction:

- Devices on your local network cannot start connections to Wi-Fi HaLow devices.
- Home Assistant itself and apps on your system can.

What this means for you: a Wi-Fi HaLow device that is compromised, or any device that joins with your passphrase, can reach other devices on your home network, in the same way a device on your ordinary Wi-Fi can. Choose a strong passphrase, share it only with devices you trust, and keep device firmware up to date.

Reaching your local network is by design. See [Supported Platforms and Known Limitations](supported-platforms-and-known-limitations.md).

## Allowed Ports

By default, Wi-Fi HaLow devices can reach only DHCP (address assignment), DNS (name lookup), and ping on your Home Assistant Green.

**Warning.** Each entry you add makes a service reachable to every device on the Wi-Fi HaLow network, including services published by other apps. Add only services you understand and intend to expose.

For example, listing the port of the Home Assistant web interface would make its login page reachable from every Wi-Fi HaLow device. The app refuses some management ports (22, 22222, 4357, and 62000 to 65500). It does not know which other services run on your system, so the choice of what to expose is yours.

## Your Passphrase

- The passphrase is required, has no default, and is 12 to 63 standard keyboard characters.
- Every device uses the same passphrase. To change it, set a new one on the Configuration page, restart the app, and update every device.
- The app does not display the passphrase on the status page.
- The passphrase is stored with the app's settings by Home Assistant. **A Home Assistant backup of this app includes the passphrase.** Keep backups private, and delete backups you no longer need.
- While the app runs, the generated radio configuration that contains the passphrase is kept in memory-backed storage.
- Diagnostics have the passphrase removed.
- Never post your passphrase in a support request, a screenshot, or a public forum. Support does not need it.

## Diagnostics and What They Contain

The "Diagnostics for support" link on the status page produces a text report. It contains:

- The same status information as the page: your settings, what is in use, the adapter and network state.
- The MAC and IP addresses of connected devices, and of devices behind a bridging device.
- Technical detail about the system compatibility check.
- A short, redacted tail of recent app messages.

The passphrase is removed. Diagnostics include device addresses. Because GitHub Issues are public, remove or mask the MAC and IP addresses before you post them.

## Who Can See the Status Page

Anyone who can open the app's panel in Home Assistant can see the status page. It shows the MAC and IP addresses of connected devices. The page is read-only. It is reachable only through Home Assistant, and the app is designed so that the status page cannot be reached from the Wi-Fi HaLow network. If you give other people access to your Home Assistant, consider whether they should see device addresses.

## What Is Stored About Devices

- The address-assignment service keeps a record of which device holds which address. It stores each device's MAC address, IP address, lease expiry, and DHCP client identifier. This record survives an app restart, is not included in Home Assistant backups, and is deleted when the app is uninstalled.
- Hostnames that devices send are not stored. A device name supplied over DHCP is therefore not added to the gateway's DNS.
- The status information, including addresses, is held in memory and is gone at every restart.
- Routine address-assignment messages are not written to the app's log. Some error messages in the log can name a device's MAC address, for example when no addresses are left in the range.
- The app does not send reports of its own. Traffic from Wi-Fi HaLow devices leaves your Home Assistant Green like any other traffic on your network.

## Backups

A Home Assistant backup of this app includes its settings, including the passphrase. The record of which device holds which address is not included. After a restore, devices ask for their addresses again.

## Good Practice

- Use a long, unique passphrase.
- Do not add entries to Allowed ports unless you need them.
- Keep Home Assistant backups private.
- Update the app and Home Assistant OS together, as described in [App Management](update-and-uninstall.md).
- Review the diagnostics before you share them.

## Reporting a Security Issue

Do not report security vulnerabilities through public GitHub Issues. Report a suspected vulnerability through the [Morse Micro security-disclosure form](https://www.morsemicro.com/policy/security-disclosure). Include the app version and your Home Assistant Operating System version, and do not include your Wi-Fi passphrase. See [SECURITY.md](../SECURITY.md).
