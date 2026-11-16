# Building

You need Xcode's command line tools, [just](https://github.com/casey/just), and a checkout of
the client next to this one:

```sh
git clone --recurse-submodules -b pbs-mackup https://github.com/0x23me/proxmox-backup-macos ../proxmox-backup-macos
cd ../proxmox-backup-macos && git checkout "$(cat ../pbs-mackup/client.commit)" && just build
```

The client's build needs Rust and Homebrew's `openssl@3`, `zstd` and `pkgconf`; its
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
overrides it) and the client built in `../proxmox-backup-macos` with `just build`, from exactly
the commit named in `client.commit`. To move to a newer client, check it out there, build it,
and put its commit into `client.commit`. `PBS_MACKUP_CLIENT` names another client binary and
skips that check.

`bundle.sh` refuses a client that loads a library macOS does not ship or has a library search
path, and nothing in the bundle may load another developer's library; the run tool of a release
build does not start a `proxmox-backup-client` that may.
Signed with a developer's identity, the app, `pbs-mackup-run` and the client get the
entitlement `com.apple.security.application-groups` for `<Team ID>.<bundle identifier>`, which
`bundle.sh` writes from the Team ID in the signature. A release build starts only a client
signed by the same team as `pbs-mackup-run` and under the client's own identifier
(`<bundle identifier>.client`), and checks the started client again
before it lets it run: every client starts suspended (`Client.launch`), also the one that
makes a new key, which gets no input that could be held back.

With `PBS_MACKUP_RUN_TOOL_PROFILE=<file>` the run tool keeps the token and the key in the data
protection keychain, in the access group `<Team ID>.<bundle identifier>`, where macOS lets no
program of another developer read, make, replace or delete an item. macOS lets a program into
such a group only by a provisioning profile, and looks for the profile in the bundle the
program is the main program of. So the run tool gets a bundle of its own inside the app,
`Contents/Helpers/PBSMackupRun.app`, with the profile as `Contents/embedded.provisionprofile`
and the entitlements `com.apple.application-identifier`, `com.apple.developer.team-identifier`
and `keychain-access-groups`. The launchd jobs start it there, and
`Contents/MacOS/pbs-mackup-run` is a link to it, so the path for the terminal stays. The run
tool finds the app from where it lies (`Identity.app`), and asks macOS whether it is in the
group (`Keychain.place`); it does not go by the path. The profile is a Developer ID profile
from the developer's account, for the App ID `<bundle identifier>.tool` with Keychain Sharing
and for the certificate that signs. `bundle.sh` checks that it is for this identifier, this
team and this certificate, allows the group and has not expired, and starts the built tool
once: macOS ends a program at once whose profile does not agree with what it asks for.
A release is always built this way. Without the variable the run tool lies in
`Contents/MacOS` itself and keeps the token and the key in the login keychain, as up to 0.5.0;
that is what a build signed ad hoc and a build by someone without such a profile get. A build
with a profile moves the items of a build without one into its keychain
([reference](reference.md#files)); a build without one does not find them there. Keychain
items are not touched by the tests.

`pbs-mackup-run` is signed as `<bundle identifier>.tool`, and that name is a promise. The
login keychain hands the token and the key to the program that stored them, which it knows by this
name and the developer, not by a version: every run tool ever released under the name can
read what is there for good, and every run tool with a profile under the name is in the access
group. So a run tool must never hand a secret, or what it unlocks, to a caller it
has not checked. The tools before 0.2 did (they signed as `.run`); if one ever has to be given
up again, it needs a new name. The items do not follow by themselves then: an item under the
old name is one any program could have put there, so the owner enters the token again and
imports the recovery copy of the key. The launchd
jobs need new names then as well: launchd remembers for a job's name which program it may
start, by the name that program was signed as when the job was first registered, and refuses
any other ("Launch Constraint Violation") also after the job is registered again. That is why
the scheduled job, `.run` before 0.2, is `.scheduled` now.

The bundle has three launchd jobs in `Contents/Library/LaunchAgents`, all of them the run tool:
`.scheduled` (every five minutes, a background job), `.manual` (Back Up Now, not a background
job) and `.helper` (the service the app talks to). The app registers them when it starts, and
again when it moved or was built anew, because launchd starts only the run tool it found when
the jobs were registered. A build signed ad hoc (`PBS_MACKUP_SIGN_IDENTITY=-`) has no team: no
entitlement, the snapshot is mounted in the cache, where the lists of file names and the
client's home folder (`Paths.clientHome`) are kept as well and any program of the user can
write, and the client's signature is not checked. Its helper has no signature to know the app
by, and any program of the user can connect to it, so it asks for Touch ID or the login
password for what the run tool asks for when it is started from a terminal: listing or
searching backups, restoring, measuring a folder, saving the settings. It asks once for each
running program that connects, so the app is asked once until it quits and another program is
asked about anew; what changes or hands out the key asks every time.

A debug build (`swift build`, the tests) also takes `clientPath` from the configuration,
`PBS_MACKUP_CLIENT` and `PBS_MACKUP_HOME`. It has no helper job: the app starts the run tool as
a program and sets `PBS_MACKUP_APP`, so that the tool does not ask to confirm. For the tests,
`PBS_MACKUP_APP=unchecked` puts the caller in the place of whoever connects to the helper of an
ad-hoc build, and `PBS_MACKUP_CONFIRM=refuse` answers no wherever the tool would ask. The app
that `just bundle` builds ignores all of these, runs only the client inside it and asks its run
tool only through the helper job.

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
when not set), stored once with `xcrun notarytool store-credentials`, and the run tool's
provisioning profile in `PBS_MACKUP_RUN_TOOL_PROFILE`; without that no release is made. Attach the zip to the
GitHub release `v0.1.1` and copy the cask into the tap's `Casks` folder.

`PBS_MACKUP_BUNDLE_ID` sets the bundle identifier, from which the Keychain service (`.tool`),
the keychain access group and the launchd jobs (`.scheduled`, `.manual`, `.helper`) take their names. Changing it makes a different app as far as macOS is
concerned: Full Disk Access and the Keychain items belong to the old one.

`just icon` redraws the icon from `Scripts/icon.swift`.
