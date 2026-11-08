# Saddle

Saddle is a macOS menu bar app that mounts an SFTP server as a Finder volume, in the spirit of Mountain Duck. Each saved connection is a File Provider domain. The menu bar app (`saddle/`) edits profiles and asks you to trust host keys. The File Provider extension (`SaddleFileProvider/`) enumerates, reads, and writes the remote files. Shared code (`Shared/`) is the SSH session, keychain, and known-hosts store.

## Requirements

- macOS 27.2 or later
- Xcode 27.2 or later
- A development team, so the app and the extension can share an App Group and the data-protection keychain

Open `saddle.xcodeproj` and run the `saddle` scheme. The extension is embedded in the app. Unit tests live in the `saddleTests` target:

```sh
xcodebuild test -project saddle.xcodeproj -scheme saddle -destination 'platform=macOS' -only-testing:saddleTests
```

There is no Swift toolchain in the environment that produced the current branch, so those tests were not executed here.

## How a connection works

1. You save a host, a remote folder, and either a password or an OpenSSH private key (Ed25519 or RSA). Secrets go to the shared keychain, not `profiles.json`.
2. Connect verifies the server key. A new key must be accepted in the app. A changed key shows the old and new fingerprints and is not stored unless you replace it. The extension refuses both cases on its own, because it cannot show UI.
3. Finder talks to the extension. Item identifiers are stable UUIDs mapped to remote paths. Remote changes are detected by re-listing directories Finder has already opened.

Deletes are permanent. SFTP has no trash.

## Limits worth knowing

- Versions are the remote size plus modification time in whole seconds. Two different edits in the same second with the same size look identical, and the later upload can replace the earlier one.
- Symbolic links are shown, but not followed. Saddle will not open or write through a link, and a recursive delete unlinks the link instead of walking its target.
- `~/.ssh/config` import follows OpenSSH's "first value wins" rule and skips `Match` and `Include`.
- Changing a password or key passphrase on a connection that is already mounted takes effect the next time that SSH session reconnects. Changing the host, user, port, remote folder, or key file drops the session immediately.
