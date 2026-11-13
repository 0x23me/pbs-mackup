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
take and mount real APFS snapshots. The other tests also run on GitHub for every push to `main`
and every pull request (`.github/workflows/test.yml`); they need no client and no server.
`Package.swift` asks for the same macOS version as the app.

`just bundle` needs a "Developer ID Application" signing identity (`PBS_MACKUP_SIGN_IDENTITY`
overrides it) and the client built in `../proxmox-backup-macos` with `just build` (which needs
FUSE-T installed; the built app runs without it), from exactly
the commit named in `client.commit`. To move to a newer client, check it out there, build it,
and put its commit into `client.commit`. `PBS_MACKUP_CLIENT` names another client binary and
skips that check.

The bundle holds the client twice. The first copy loses its library search path
(`/usr/local/lib`); the second keeps it and is only used for `mount`. Only that second copy is
signed with the entitlement in `Scripts/client.entitlements`, which lets it load FUSE-T's
library; the run tool of a release build does not start a `proxmox-backup-client` that has it.
Signed with a developer's identity, the app, `pbs-mackup-run` and both clients get the
entitlement `com.apple.security.application-groups` for `<Team ID>.<bundle identifier>`, which
`bundle.sh` writes from the Team ID in the signature. A release build starts only a client
signed by the same team as `pbs-mackup-run` and under the client's own identifier
(`<bundle identifier>.client`, for `mount` `.client-mount`), and checks the started client again
before it hands over the key.

`pbs-mackup-run` is signed as `<bundle identifier>.tool`, and that name is a promise. The
Keychain hands the token and the key to the program that stored them, which it knows by this
name and the developer, not by a version: every run tool ever released under the name can
read them for good. So a run tool must never hand a secret, or what it unlocks, to a caller it
has not checked. The tools before 0.2 did (they signed as `.run`); if one ever has to be given
up again, it needs a new name, and `Keychain.migrate` shows how the items follow. The launchd
jobs need new names then as well: launchd remembers for a job's name which program it may
start, by the name that program was signed as when the job was first registered, and refuses
any other ("Launch Constraint Violation") also after the job is registered again. That is why
the scheduled job, `.run` before 0.2, is `.scheduled` now.

The bundle has three launchd jobs in `Contents/Library/LaunchAgents`, all of them the run tool:
`.scheduled` (every five minutes, a background job), `.manual` (Back Up Now, not a background
job) and `.helper` (the service the app talks to). The app registers them when it starts, and
again when it moved or was built anew, because launchd starts only the run tool it found when
the jobs were registered. A build signed ad hoc (`PBS_MACKUP_SIGN_IDENTITY=-`) has no team: no
entitlement, the snapshot is mounted in the cache, and the client's signature is not checked.

A debug build (`swift build`, the tests) also takes `clientPath` from the configuration,
`PBS_MACKUP_CLIENT` and `PBS_MACKUP_HOME`. It has no helper job: the app starts the run tool as
a program and sets `PBS_MACKUP_APP`, so that the tool does not ask to confirm. The app that
`just bundle` builds ignores all four, runs only the client inside it and asks its run tool
only through the helper job.

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

`.build/debug/PBSMackup --shot settings|timeline <file.png>` starts the app as usual, opens that window and
saves a picture of it with its frame, which is how the pictures in the README are made (in a
virtual machine with a made-up home folder). `PBS_MACKUP_RENDER_OPEN` names the folder the
Backups window shows, such as `me.pxar/Documents`. Both picture modes are in a debug build only
(`swift build`); the app that `just bundle` makes is a release build and has neither.

## Releasing

Put the new version into `VERSION`, commit, and push a tag for it:

```sh
git tag -a v0.1.1 -m "What changed"
git push origin v0.1.1
```

The release workflow (`.github/workflows/release.yml`) builds the client from `client.commit`,
builds, signs and notarizes the app, creates the GitHub release `v0.1.1` with the zip (the tag's
message as its notes) and puts the cask into the tap. The secrets it needs are listed at the top of
the workflow. Its actions are pinned to commits; when one is moved on, take the newest release
of each (`gh api repos/actions/checkout/releases/latest`). Homebrew's OpenSSL and zstd and the
runner's compilers are not pinned; the release notes say which versions went in.

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
