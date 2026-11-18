# App Management

This guide covers updating the app, updating Home Assistant OS, installing earlier versions, and stopping and removing the app. It also says what the app leaves on your system.

## Before Any Update

Create a Home Assistant backup first. A backup of this app includes its settings, including the passphrase, so keep backups private.

## Update the App

Update the app from the Home Assistant app store when a new version is available. After the update, restart the app if Home Assistant does not do it for you, and open the status page to confirm that the state is Operating.

Updating the app through the app store while it is running has not been verified. Create a backup first.

Saved settings: the app keeps its settings across a restart. This is the first version of the app, so no earlier version exists to update from.

## Update Home Assistant OS

Read this before you update Home Assistant OS.

This release supports Home Assistant OS 18.4. Because the app includes a driver matched to your Home Assistant OS build, some OS updates may require a compatible app update. The app accepts one exact Home Assistant OS build, so even a rebuild with the same version number can be refused.

1. Before updating Home Assistant OS, check that a compatible app version is available.
2. Create a backup.
3. Update Home Assistant OS.

If the installed version is not supported, the Wi-Fi HaLow Access Point stays off, and the app does not apply new radio or network changes. The status page shows `UNSUPPORTED_KERNEL` and explains what to do. To recover, update the app to a compatible version, then restart it. The rest of Home Assistant is not affected. Your Wi-Fi HaLow devices cannot connect until the Access Point is running again.

The app refuses a Home Assistant OS build it does not recognize. Support for additional Home Assistant OS systems is planned for future releases, and this guide gives no date or list of versions.

## Install an Earlier Version

The app has no rollback button. If a new version does not work, you have these options:

- **Restore a backup.** Restore the Home Assistant backup you made before the update.
- **Install the earlier app version again**, if it is still offered in the app store. Earlier versions are not guaranteed to stay available.
- **Return to a clean state.** If the status page shows `ROLLBACK_INCOMPLETE`, restart Home Assistant Green from the System page. This restarts your whole Home Assistant system, not only this app.

If you roll back Home Assistant OS to an earlier build, check that a compatible app version is available for that build.

## Stop the App

Stop the app from its page in Home Assistant.

- Stopping the app disconnects all devices.
- The firewall rules and the network bridge that the app added are removed, and the radio driver is unloaded.
- The app records what it changes and undoes it in a fixed order. If it cannot confirm that everything was undone, it says so on the status page (`ROLLBACK_INCOMPLETE`).
- Stopping can take up to about a minute and a half while the app undoes its changes. Home Assistant waits up to 120 seconds before it forces the app to end.

### What Stays Behind After You Stop

Restart Home Assistant Green after removing the app to clear the remaining temporary driver and firmware-search state. This state is harmless, and it clears at the restart. For technical detail, see [Security and Privacy](security-and-privacy.md).

If a stop is cut off, the next start finds and removes the leftovers first.

## Uninstall the App

1. Stop the app.
2. Select Uninstall on the app's Info page.
3. Restart Home Assistant Green from the System page to clear the remaining temporary driver and firmware-search state. See [Security and Privacy](security-and-privacy.md) for detail.

What uninstalling removes: the app, its container and image, and its stored data. The record of which device holds which address is part of that data and is deleted with it. By design, the settings (including the passphrase) go with the app. Backups you made earlier still contain the settings and the passphrase, so delete backups you no longer want.

What uninstalling does not do: it does not clear the remaining temporary driver and firmware-search state (restart Home Assistant Green to clear it), and it does not change your Home Assistant backups.

## Reinstall

Install the app again as described in [Installation and First Use](installation-and-first-use.md). Your settings are not kept after an uninstall, so enter them again, or restore them from a backup. Devices ask for their addresses again after a restore.
