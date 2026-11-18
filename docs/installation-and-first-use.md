# Installation and First Use

This guide takes you from a Home Assistant Green with a Morse Micro Wi-Fi HaLow USB Network Adapter to a running Wi-Fi HaLow Access Point.

## What You Need

- **Home Assistant Green** running Home Assistant OS 18.4 is supported in this release. Support for additional Home Assistant OS systems is planned for future releases.
- **One Morse Micro Wi-Fi HaLow USB Network Adapter.** Both the USB-A and USB-C versions are supported. Connect one only; if two adapters are connected, the Access Point does not start.
- **Region.** Australia is supported in this release. Support for additional regions is planned for future releases.
- **Devices that support WPA3.** The network uses WPA3-Personal only, with no WPA2 or mixed mode, so devices that support only WPA2 cannot join.
- **A network connection** on your Home Assistant Green (Ethernet or the connection it normally uses), so that your Wi-Fi HaLow devices can reach your home network and the Internet.

Before you begin, create a Home Assistant backup. A backup of this app includes its settings, including the passphrase, so keep backups private.

## Check Your Home Assistant OS Version

The app contains a driver that must match your Home Assistant OS build exactly. In Home Assistant, open Settings, then System, then About, and check that the Operating System version is 18.4.

If your system runs a different version, do not install the app. If you install it anyway, the Wi-Fi HaLow Access Point stays off, and the status page shows the error code `UNSUPPORTED_KERNEL`. See [App Management](update-and-uninstall.md).

## Install the App

1. Open the Home Assistant app store.
2. Add the Morse Micro Labs repository (see "Add the Morse Micro Labs Repository" below).
3. Select Morse Micro Wi-Fi HaLow Access Point for Home Assistant and select Install.

## Add the Morse Micro Labs Repository

The app comes from the Morse Micro Labs repository. Add it to the Home Assistant app store once:

1. In Home Assistant, open the app store. The menu names can differ between Home Assistant versions; on current versions, open Settings, then Apps, then App Store.
2. Open the Repositories option (for example, from the menu at the top right of the app store).
3. Paste this address and select Add: `https://github.com/MorseMicroLabs/home-assistant-halow`
4. Close the dialog and reload the app store page. The app appears in the list.

## Connect the Adapter

Plug the Morse Micro Wi-Fi HaLow USB Network Adapter into a USB port on your Home Assistant Green. You can do this before or after you start the app. If the adapter is not connected, the app keeps checking and starts the Access Point once it finds the adapter.

## Set Up and Start

1. Open the app's Configuration page.
2. Enter a network passphrase. It is required and has no default. Use 12 to 63 standard keyboard characters (no accented letters or emoji).
3. Review the other settings. The network name (SSID) starts as `Wi-Fi-HaLow`, and you can change it. Every setting is described in the [Configuration Guide](configuration-guide.md).
4. Select Save, then select Start.

The app starts when Home Assistant starts. You can switch that off on the app's Info page.

## Open the Status Page

Select Open web UI on the app's Info page to see the status page. Turn on Show in sidebar to open it from the sidebar as Wi-Fi HaLow.

The status page shows one of three states:

- **Starting.** The Access Point is starting. The page updates by itself.
- **Operating.** The Access Point is running and devices can connect.
- **Attention required.** Something needs your action. The page says what happened and what to do, with an error code to quote if you contact support.

Wait for Operating before you connect a device. Every state and error code is explained in the [Status Page Explanation](status-page-explanation.md).

## Connect a Wi-Fi HaLow Device

On your Wi-Fi HaLow device, choose the network name you set, and enter the passphrase.

- The network is WPA3-Personal only. The device must support WPA3.
- If the device cannot find the network by itself, set it to the frequency and bandwidth shown under "In use now" on the status page. The status page shows both the channel number and the frequency, because some devices need the frequency.
- Your device gets an address from the app, in the range set by First client address and Last client address (by default `192.168.90.50` to `192.168.90.150`).

After the device joins, it appears under Connected devices on the status page, with its status and IP address.

## What to Expect

- Wi-Fi HaLow devices are isolated from each other, so they cannot discover each other.
- Devices can reach your home network and the Internet through your Home Assistant Green. They cannot reach services on your Home Assistant Green except DHCP (address assignment), DNS (name lookup), and ping, unless you add the port under Allowed ports.
- Home Assistant may not discover Wi-Fi HaLow devices automatically, because the Wi-Fi HaLow network is separate. Adding devices by IP address may work where an integration offers it.
- The app provides no Home Assistant entities, notifications, or per-device controls.

For the full list of what devices can and cannot reach, see [Security and Privacy](security-and-privacy.md).

## After You Change a Setting

Changes take effect when you restart the app. Home Assistant prompts you to restart after you save. If you decline the prompt, the Access Point keeps running the previous settings until you restart the app. The status page always shows what is in use.

After you save, Home Assistant may keep showing the earlier values on the Configuration page. Reload the page (Ctrl+F5, or pull down to refresh in the Companion app) before you change anything else.

## If Something Does Not Work

Start with the status page. If it shows Attention required, follow its "What to do" text. For other problems, see [Troubleshooting and Recovery](troubleshooting-and-recovery.md).
