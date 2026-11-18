# Status Page Explanation

The status page shows whether the Access Point is starting, is operating, or needs attention. Open it with Open web UI on the app's Info page. If you turn on Show in sidebar, it opens from the sidebar as Wi-Fi HaLow.

The page is read-only. It has no buttons that change anything, and it updates by itself about every 5 seconds.

## What the Page Shows

The page is titled "Wi-Fi HaLow access point". From top to bottom it contains:

1. The overall state (Starting, Operating, or Attention required).
2. A notice if the status may be out of date.
3. An Attention required box, when attention is needed.
4. A "Using a backup channel" notice, when automatic channel selection did not complete.
5. A "Wi-Fi HaLow radio" section with "Your settings" and "In use now".
6. An "Adapter and network" section.
7. A "Connected devices" section.
8. A footer with the last update time and a link to the diagnostics.

Times on the page are shown in UTC, in the form `2026-01-31 14:05:09 UTC`.

## Overall State

| State | What the page says | What it means | What to do |
|---|---|---|---|
| Starting | "The access point is starting. This page updates by itself." | The app is starting the Access Point. | Wait. If it stays on Starting for several minutes, see [Troubleshooting and Recovery](troubleshooting-and-recovery.md). |
| Operating | "The access point is running and devices can connect." | The Access Point is running and devices can connect. | Nothing. |
| Attention required | The problem, a "What to do" line, and an error code | The Access Point is off or has a problem that needs your action. | Follow the "What to do" text. Error codes are listed below. |

## Your Settings and In Use Now

Under "Wi-Fi HaLow radio", the page shows two groups.

**Your settings** shows what you saved:

| Row | What it shows |
|---|---|
| Region | The region you set. |
| Channel selection mode | Automatic or Manual. |
| Bandwidth setting | The bandwidth you set. |
| Channel setting | "Automatic (chosen each time the app starts)" in automatic mode, or the channel you set in manual mode. |

The page notes that changes to the app options take effect after you restart the app.

**In use now** shows what the Access Point is actually using:

| Row | What it shows |
|---|---|
| Frequency | The center frequency in MHz. |
| Channel | The channel number. |
| Bandwidth | The channel width. |
| Channel chosen by | "Automatic selection", "Your manual setting", or "Backup channel (automatic selection did not complete)". |
| Active since | When these values took effect. |

If a device cannot find the network by itself, set it to the frequency and bandwidth shown under "In use now".

Other things you may see in this section:

- "Last values used (access point not running)" with a time: the Access Point is not running, so the page shows the last values it used.
- "The access point is running, but its active radio values cannot be read right now. The values above are your settings.": the Access Point is running, but the page cannot read back the active values.
- "Not available yet. The access point has not started.": the Access Point has not started since the app began.
- "Not reported": a value is not available.

## Adapter and Network

| Row | Values | Meaning |
|---|---|---|
| Wi-Fi HaLow USB Network Adapter | Detected, Not detected | Whether the app found the adapter. |
| Networking | Active, Not active | Whether the private Wi-Fi HaLow network (bridge, address assignment, and routing) is set up. |

## Connected Devices

The table lists devices that have joined the Wi-Fi HaLow network since the app started. On a narrow screen, each device appears as a stacked record with the same labels.

| Column | Meaning |
|---|---|
| Device (MAC address) | The device's hardware address. |
| Status | Online or Offline. "status estimated" appears under the status when it was worked out from connection events rather than read directly. |
| Time | "Connected since" with a time for an online device, or "Last change" with a time. |
| IP address | The address or addresses the device uses, or "Not available". |

Online and Offline show the connection to the Access Point, not whether a device is sending data.

Some devices connect other devices (a bridging device). Such a device is marked "Connects other devices", and its row lists "This device" and the addresses of the devices behind it. If devices are left out because of display limits, the row says "N more devices not shown." If none are connected through it, the row says "No other devices are connected through it right now." or "No other devices listed."

If two devices appear to use the same address, the page adds "Another device may also use this address."

If no device has joined, the page says "No devices have connected since the app started."

## Notices

### Status may be out of date

This notice appears when the status has not been updated for about 90 seconds.

- Page text: "The status has not been updated recently, so what you see may be out of date."
- What to do: "Restart the app. If the message stays, check the app's Log tab."
- Error code: `STATUS_STALE`.

A separate line at the top of the page, "The status page cannot reach the app right now, so what you see may be out of date.", appears when your browser cannot reach the status page. Reload the page and check that the app is running.

### Using a backup channel

This notice is an advisory, not a problem. The Access Point is running.

- Page text: "Automatic channel selection did not complete, so the access point started on a backup channel."
- What to do: "Wi-Fi HaLow devices can connect on the channel shown below. Restart the app to try automatic selection again, or set Channel selection mode to manual and choose a channel."
- Error code: `RADIO_AUTO_FALLBACK`.

## Attention Required

When attention is needed, the Attention required box shows:

- A summary of what happened.
- "What to do:" with the next step.
- "Details:", when the app has more to say (for example the name of the setting).
- Since: when the problem started.
- System state: either "The app has undone its changes to the system." or "The app could not confirm that its changes to the system were undone."
- Error code: the code to quote if you contact support.

Three codes are recoverable: the app keeps checking by itself and continues when the condition clears. They are marked "retries by itself" below. `AP_START_FAILED` and `AP_DIED` retry a few times on their own.

## Error Codes

| Code | What the page says | What to do |
|---|---|---|
| `NO_ADAPTER` (retries by itself) | The Morse Micro Wi-Fi HaLow USB Network Adapter was not found. | Plug the adapter into your Home Assistant Green. The app keeps checking and starts the access point once it finds the adapter. |
| `MULTIPLE_ADAPTERS` (retries by itself) | More than one Morse Micro Wi-Fi HaLow USB Network Adapter is connected. | Leave one adapter connected and unplug the others. The access point starts automatically once only one adapter is present. |
| `UNSUPPORTED_KERNEL` | This version of the app does not support the Home Assistant OS version on your system. | Update the app to a version that supports your Home Assistant OS version, then restart it. Until then the Wi-Fi HaLow access point stays off, and the app does not apply new radio or network changes. |
| `REGION_UNVALIDATED` | The selected region is not supported by this version of the app. | Choose a supported Region and restart the app. |
| `CONFIG_INVALID` | A setting has a value the app cannot use. | Change the setting named in the details to a valid value, then restart the app. |
| `FIRMWARE_INVALID` | The adapter's firmware or driver files in the app did not pass their check. | Update or reinstall the app, then restart it. |
| `MODULE_LOAD_FAILED` | The adapter's driver could not be loaded or did not start. | Restart the app. If it happens again, update the app to the latest version. |
| `HOST_STATE_FAILED` | A system setting the app needs could not be checked or changed, so the access point did not start. | The details name the setting. Restart the app. If the details mention IP forwarding (a system setting that lets traffic pass through), restart Home Assistant Green from the System page instead, because the app does not change it. If it happens again, update the app to the latest version. |
| `AP_START_FAILED` | The Wi-Fi HaLow access point could not start. | The app retries a few times on its own. If this message stays, check Region, Bandwidth, Channel selection mode, and Channel, then restart the app. |
| `AP_DIED` | The Wi-Fi HaLow access point stopped unexpectedly. | The app retries a few times on its own. If this message stays, restart the app. |
| `BACKEND_FAILED` | The Wi-Fi HaLow network could not be set up or kept running. | Check that Wi-Fi HaLow network address does not overlap another network. If the details name a port, make sure nothing else on your Home Assistant Green uses it. Then restart the app. If it happens again, update the app to the latest version. |
| `NM_CHECK_FAILED` | The app could not stop Home Assistant from managing the adapter and the Wi-Fi HaLow network. | Restart the app. If it happens again, restart Home Assistant Green from the System page, then update the app to the latest version. |
| `UPLINK_UNAVAILABLE` (retries by itself) | No network connection was found for your Wi-Fi HaLow devices to reach the rest of your network. | Check that your Home Assistant Green is connected to your network. If you set Uplink interface, check that it is correct. If default routes use more than one interface, enter the interface name in Uplink interface. The app keeps checking and continues automatically when a connection is available. |
| `ROLLBACK_INCOMPLETE` | The app could not confirm that it undid all of its changes to your system, so it does not apply new radio or network changes. | Restart Home Assistant Green from the System page to return it to a clean state. This restarts your whole Home Assistant system, not only this app. |
| `STATUS_STALE` | The status has not been updated recently, so what you see may be out of date. | Restart the app. If the message stays, check the app's Log tab. |
| `RADIO_MISMATCH` | The access point is using radio settings that differ from your settings. | Check Region, Bandwidth, Channel selection mode, and Channel, then restart the app. If it happens again, update the app to the latest version. |
| `INTERNAL_ERROR` | The app ran into an unexpected problem. | Restart the app. If it happens again, update the app to the latest version and keep the diagnostics for support. |

The advisory `RADIO_AUTO_FALLBACK` is described under "Using a backup channel" above.

If the problem continues after you follow the steps, see [Troubleshooting and Recovery](troubleshooting-and-recovery.md) and [Help and Support](help-and-support.md).

## Diagnostics for Support

The footer of the page links to "Diagnostics for support", with the note "(passphrase removed; includes device addresses)".

The diagnostics contain the same status information as the page (your settings, what is in use, adapter and network state, and connected devices with their MAC and IP addresses), plus technical detail about the system check and a short, redacted tail of the app's recent messages. The passphrase is removed. Diagnostics include device addresses. Because GitHub Issues are public, remove or mask the MAC and IP addresses before you post them.

## What You Cannot See Here

The status page does not show traffic, signal strength, or per-device controls. The app provides no Home Assistant entities or notifications, so nothing about the Access Point appears elsewhere in Home Assistant.

## Rare Conditions

Some error conditions are rare. If what you see differs from the description, see [Help and Support](help-and-support.md).
