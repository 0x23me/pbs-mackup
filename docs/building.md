# Building

You need Xcode's command line tools, [just](https://github.com/casey/just), and a checkout of
the client next to this one:

```sh
git clone --recurse-submodules -b pbs-mackup https://github.com/0x23me/proxmox-backup-macos ../proxmox-backup-macos
cd ../proxmox-backup-macos && git checkout "$(cat ../pbs-mackup/client.commit)" && just build
```

The client's build needs Rust, Homebrew's `openssl@3`, `zstd` and `pkgconf`, and FUSE-T; its
`README.macos.md` has the details. OpenSSL and zstd are linked into the client, so the app
runs on a Mac without Homebrew. It then needs the macOS version Homebrew built them for,
which is why the app asks for macOS 26.

```sh
just run
just install
just backup
just test
just test-snapshots
```

`run` builds, signs and starts the app from `.build`, `install` puts it into `/Applications`,
`backup` does one run from the terminal. `test-snapshots` adds the run tool's tests, which
take and mount real APFS snapshots.

`just bundle` needs a "Developer ID Application" signing identity (`PBS_MACKUP_SIGN_IDENTITY`
overrides it) and the client built in `../proxmox-backup-macos` with `just build` (which needs
FUSE-T installed; the built app runs without it), from exactly
the commit named in `client.commit`. To move to a newer client, check it out there, build it,
and put its commit into `client.commit`. `PBS_MACKUP_CLIENT` names another client binary and
skips that check.

The app is signed with the same identity and identifier on every build, so Full Disk Access
and the Keychain items stay valid across rebuilds and reinstalls. Use one copy at a time: the
copy that was started last owns the launchd job. `just test-snapshots` needs Full Disk Access
for the terminal.

Mounting an APFS snapshot needs Full Disk Access for the app (System Settings, Privacy &
Security). Without it a run reads the live folders and says so, unless `frozenSnapshot` is
`required`, in which case it fails.

`.build/debug/PBSMackup --render settings <file.png> [server|key]` draws the settings window into
an image and exits, to look at a layout change without clicking through the app. It shows the
stored configuration and the last measurement, and touches neither the Keychain nor launchd.
`PBS_MACKUP_RENDER_SOURCES` sets the backed-up folders for the picture, `PBS_MACKUP_RENDER_EXPAND` the
folders to show open (paths below the first one, separated by colons).

`PBSMackup --shot settings|timeline <file.png>` starts the app as usual, opens that window and
saves a picture of it with its frame, which is how the pictures in the README are made (in a
virtual machine with a made-up home folder). `PBS_MACKUP_RENDER_OPEN` names the folder the
Backups window shows, such as `me.pxar/Documents`.

## Releasing

Put the new version into `VERSION`, commit, and push a tag for it:

```sh
git tag -a v0.1.1 -m "What changed"
git push origin v0.1.1
```

The release workflow (`.github/workflows/release.yml`) builds the client from `client.commit`,
builds, signs and notarizes the app, creates the GitHub release `v0.1.1` with the zip (the tag's
message as its notes) and puts the cask into the tap. The secrets it needs are listed at the top of
the workflow.

To make the same release on this Mac instead:

```sh
just release 0.1.1
```

builds, signs and notarizes `dist/PBSMackup-0.1.1.zip`, and writes the Homebrew cask for it to
`dist/pbs-mackup.rb`. It needs a notarytool keychain profile (`PBS_MACKUP_NOTARY_PROFILE`, `pbs-mackup`
when not set), stored once with `xcrun notarytool store-credentials`. Attach the zip to the
GitHub release `v0.1.1` and copy the cask into the tap's `Casks` folder.

`PBS_MACKUP_BUNDLE_ID` sets the bundle identifier, which is also the Keychain service and, with
`.run` appended, the launchd job. Changing it makes a different app as far as macOS is
concerned: Full Disk Access and the Keychain items belong to the old one.

`just icon` redraws the icon from `Scripts/icon.swift`.
