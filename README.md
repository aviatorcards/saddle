# Saddle

Saddle is a macOS menu bar app that mounts SFTP servers as Finder volumes, in the spirit of Mountain Duck. Each saved connection runs as an independent File Provider domain. The menu bar app (`saddle/`) edits profiles, configures preferences, and manages host key verification. The File Provider extension (`SaddleFileProvider/`) enumerates, reads, and writes remote files. Shared code (`Shared/`) manages the SSH session, keychain access, and known-hosts store.

## Requirements

- macOS 27.2 or later
- Xcode 27.2 or later
- A development team, so the app and the extension can share an App Group and the data-protection keychain

Open `saddle.xcodeproj` and run the `saddle` scheme. The extension is embedded in the app. Unit tests live in the `saddleTests` target:

```sh
xcodebuild test -project saddle.xcodeproj -scheme saddle -destination 'platform=macOS' -only-testing:saddleTests
```

## How a connection works

1. You save a host, a remote folder, and either a password or an OpenSSH private key (Ed25519 or RSA). Secrets go to the shared keychain, not `profiles.json`.
2. Connect verifies the server key. A new key must be accepted in the app. A changed key shows the old and new fingerprints and is not stored unless you replace it. The extension refuses both cases on its own, because it cannot show UI.
3. Finder talks to the extension. Item identifiers are stable UUIDs mapped to remote paths. Remote changes are detected by re-listing directories Finder has already opened.

Deletes are permanent. SFTP has no trash.

## Settings & Preferences

Saddle includes a dedicated macOS Settings window (accessible via `⌘,`, from the menu bar popover header or footer, or within the Connections manager):

- **General**:
  - **Launch at Login**: Enable or disable automatic background launch at user login via `SMAppService`.
  - **Finder Integration**: Automatically open and reveal the mounted directory in Finder upon connection.
  - **Notifications**: Granular toggles for connection failure alerts, successful mount notices, and disconnection alerts.
- **Connection Defaults**:
  - Configure initial values for newly created connections (default port, default username, remote directory, default parallel SFTP channels 1–8, remote refresh check interval, and hidden file visibility).
- **Known Hosts**:
  - Inspect all trusted SSH server host keys stored in Saddle's `known_hosts.json`.
  - Search and filter by hostname, port, or SHA-256 fingerprint.
  - Copy fingerprints to clipboard or forget individual/all host keys to prompt verification on subsequent connections.
- **Advanced**:
  - Inspect the App Group shared container directory with one-click "Reveal in Finder".
  - View logged event counts and clear the activity log.
  - App version and architecture overview.

## Limits worth knowing

- Versions are the remote size plus modification time in whole seconds. Two different edits in the same second with the same size look identical, and the later upload can replace the earlier one.
- Symbolic links that resolve inside the mounted folder appear as their targets, so a linked folder is browsable and a linked file opens and saves normally (saves go to the target). Links that point outside the mounted folder, or nowhere, are not shown. Deleting a link only removes the link, and a recursive delete never walks into a linked folder.
- Overwriting a file moves the previous version aside as `.saddle-<id>.<name>.bak` until the new bytes are in place. If an upload is interrupted and the original is missing, that backup stays visible so you can recover it.
- `~/.ssh/config` import follows OpenSSH's "first value wins" rule and skips `Match` and `Include`.
- Changing a password or key passphrase on a connection that is already mounted takes effect the next time that SSH session reconnects. Changing the host, user, port, remote folder, or key file drops the session immediately.
