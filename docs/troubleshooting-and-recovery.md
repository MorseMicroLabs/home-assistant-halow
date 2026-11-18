# Troubleshooting and Recovery

Start with the status page. It says whether the Access Point is starting, running, or needs attention, and it gives an error code. Open it with Open web UI on the app's Info page. Every error code is explained in the [Status Page Explanation](status-page-explanation.md).

## First Checks

1. Open the status page.
2. If it shows Attention required, follow the "What to do" text.
3. Check that the adapter shows Detected under "Adapter and network".
4. Check that the Home Assistant OS version is supported. See [App Management](update-and-uninstall.md).
5. Restart the app. Many conditions clear after a restart.

## Problems and Fixes

### Nothing seems to happen after you select Start

Open the status page first. It says whether the Access Point is starting, running, or needs attention. After a Home Assistant restart, the Access Point can take a few minutes to reach Operating.

If you pressed Start before saving a passphrase, Home Assistant reports a missing-option error and the app does not start, so there is no status page. Set a passphrase on the Configuration page, select Save, then select Start.

### The adapter is not found

The status page shows `NO_ADAPTER`. Plug the adapter into your Home Assistant Green. The app keeps checking and starts the Access Point automatically. If it still is not found, try another USB port, then restart the app.

### More than one adapter is connected

The status page shows `MULTIPLE_ADAPTERS`. Leave one adapter connected and unplug the others. The Access Point starts automatically once only one adapter is present.

### A device cannot find the network

- Set the device to the frequency and bandwidth shown under "In use now" on the status page. Some devices need the frequency instead of the channel number.
- Make sure the device supports WPA3. The network is WPA3-Personal only, so devices that support only WPA2 cannot join.
- Check the network name and passphrase on the device.
- Confirm that the status page shows Operating.

### A device joins but has no network access

- Check that your Home Assistant Green is connected to your network. If it is not, the status page shows `UPLINK_UNAVAILABLE`.
- If you set Uplink interface, check that the name is correct, or leave it empty. If default routes use more than one interface, the app cannot choose between them, so enter the interface name in Uplink interface.
- Check that the device got an address in the client address range. It appears under Connected devices with its IP address.
- Remember that devices reach your Home Assistant Green only for DHCP, DNS, and ping, unless you add the port under Allowed ports. See [Configuration Guide](configuration-guide.md).

### Home Assistant does not find my Wi-Fi HaLow devices

The Wi-Fi HaLow network is separate from your home network, so Home Assistant may not discover devices automatically. Adding devices by IP address may work where an integration offers it. Devices on your local network cannot start connections to Wi-Fi HaLow devices. Home Assistant itself and apps on your system can.

### The Access Point started on a backup channel

The status page shows "Using a backup channel" (`RADIO_AUTO_FALLBACK`). Automatic channel selection did not complete. Wi-Fi HaLow devices can connect on the channel shown. Restart the app to try again, or set Channel selection mode to manual and choose a channel from the table in the [Configuration Guide](configuration-guide.md).

### The Access Point does not start after you set a channel

In manual mode, the channel must fit the bandwidth. The status page shows `CONFIG_INVALID` and names the setting. Choose a channel from the Australian channel table for your bandwidth, or set Channel selection mode back to automatic. Check the channel whenever you change the bandwidth.

### Home Assistant refuses to save a channel

Pick a channel from the list, or `auto`. Home Assistant only offers channels 28 to 50 and `auto`.

### The Configuration page shows an old value after you saved

This is a known issue. Reload the page (Ctrl+F5, or pull down to refresh in the Companion app) before you change anything else, and check the status page for what is in use. Saving from an out-of-date form might overwrite other settings with old values.

### You declined the restart prompt

The Access Point keeps running the previous settings until you restart the app.

### The status page says the status may be out of date

Restart the app. If the message stays, check the app's Log tab. If your browser lost contact with the page, reload it.

### The app reports it could not confirm that it undid its changes

The status page shows `ROLLBACK_INCOMPLETE`. Restart Home Assistant Green from the System page. This restarts your whole Home Assistant system, not only this app.

### Updating Home Assistant OS stopped the Access Point

The status page shows `UNSUPPORTED_KERNEL`. Update the app to a version that supports your Home Assistant OS version, then restart it. See [App Management](update-and-uninstall.md).

### The app restarts the Access Point by itself

If the interface associated with the default route changes while the app runs, the Access Point restarts and devices reconnect.

## Recovery Steps in Order

Work through these from the least to the most disruptive.

1. **Restart the app.** Use the Restart button on the app's Info page.
2. **Check your settings.** Open the Configuration page and compare them with the [Configuration Guide](configuration-guide.md). Reload the page first.
3. **Update the app** to the latest available version, then restart it.
4. **Restart Home Assistant Green** from the System page. Use this when the status page recommends it (`ROLLBACK_INCOMPLETE`, `NM_CHECK_FAILED`, or `HOST_STATE_FAILED` with an IP forwarding message). It restarts your whole Home Assistant system.
5. **Reinstall the app.** Uninstall it, then install it again. Enter your settings again, or restore them from a backup. See [App Management](update-and-uninstall.md).
6. **Contact support.** See [Help and Support](help-and-support.md).

## What to Collect Before You Ask for Help

- The error code shown on the status page.
- The version of the app (`1.0.0`) and your Home Assistant OS version.
- The diagnostics from the footer of the status page. The passphrase is removed. Diagnostics include device addresses. Because GitHub Issues are public, remove or mask the MAC and IP addresses before you post them.
- What you were doing when the problem started, and whether it happens every time.

## Known Conditions That Are Not Errors

- The kernel may be shown as tainted after the app has loaded its driver. This clears when you restart Home Assistant Green. For the explanation, see [Security and Privacy](security-and-privacy.md).
- Offline devices are normal when a device is out of range or powered off.
- Online and Offline describe the connection to the Access Point, not whether a device is sending data.
