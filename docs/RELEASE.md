# Release preparation

The current package is a GitHub beta prerelease, Developer ID signed and not notarized.
A successful build or local signature check is not proof that a downloaded app
will open on another Mac. Public source publication does not require Apple
membership; an unnotarized binary can be blocked by Gatekeeper. The English and
Korean READMEs explain installation and this limitation.

## Local checks

```sh
zsh scripts/check-release.sh
zsh scripts/build.sh
zsh scripts/package-release.sh
```

The checks exercise backup/restore, retention, scheduling, localization, memory
usage, process termination, interrupted restores, disk-image disconnects, full
storage and corruption detection. Fault injection creates its own APFS image
and keeps artifacts under `.build`. It does not detach physical backup drives.
Ensure several GB of free space before running it.

Building produces both arm64 and x86_64. Packaging creates ZIPs, checksums and a source
export with an allowlisted file manifest. The export excludes Git history,
local evidence, backup data and build output. Initialize the public repository
from that source export rather than publishing a development checkout's history.

## Distribution signing

An ordinary local build uses an ad-hoc signature. To build with an installed
Developer ID Application identity:

```sh
CODESIGN_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)' zsh scripts/build.sh
```

The signed path enables hardened runtime and a secure timestamp. Review the
resulting artifact, then submit it with Apple's `notarytool` using your own
Keychain profile. A certificate and an authorized notarization profile are
required. Never commit certificates, private keys or credentials.

For a normal Developer ID distribution, obtain a successful notarization result,
staple its ticket to the app and run `scripts/package-release.sh` without rebuilding,
verify with Gatekeeper, and test
a browser-downloaded copy on a separate Mac. Update the ZIP checksum after any
change to the app. No signing credentials, uploads or publication are performed
by the local packaging script. Packaging verifies the embedded runtime-source
manifest and refuses stale builds. It does not rebuild or invalidate a stapled ticket.

## User data and upgrades

Replacing the application bundle must preserve Application Support settings
and backup directories. Removing the app alone does not erase backups. An
interrupted restore can leave a hidden partial folder; retry creates a new
restore folder. Never present that partial folder as a completed restore.

Support requires the complete plan backup directory, including shared data.
Copying only a dated catalog is insufficient. Backups are not encrypted.

## Release gates

- Record full restore/integrity results for actual data separately from fixtures.
- Test downloaded installation, folder permissions and login execution on a
  separate Mac and the oldest supported macOS version.
- Test Intel execution on hardware; a universal build alone does not establish it.
- Keep physical power-loss/cable-removal tests distinct from disk-image tests.
- Confirm all release artifacts correspond to the reviewed source and checksum.

References: [Apple distribution](https://developer.apple.com/macos/distribution/),
[Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).
