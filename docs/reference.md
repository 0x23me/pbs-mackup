# Reference

What the app keeps where, and the files it reads and writes. The [README](../README.md) is
the place to start.

## The parts

- `PBSMackup.app`: the menu bar app. Shows the state, starts and cancels backups, browses
  snapshots and restores items. It registers the launchd job.
- `pbs-mackup-run`, in the app: performs one backup run and exits. launchd starts it every five
  minutes and it runs when a backup is due: one interval after the last successful backup began.
  A run that was skipped (server not reachable, on battery) is tried again five minutes later. A
  failed run is tried again a quarter of an hour after it ended, then after twice as long each
  time it fails again, at most one interval. After a cancelled run a whole interval passes. The
  app asks it for everything that needs the token or the key, so the app itself never reads
  them. It is three launchd jobs: `<bundle identifier>.scheduled` is the scheduled one, a
  background job, which gets the slow cores and throttled disk and network; `.manual` is what
  Back Up Now starts, with none of that; `.helper` is what the app talks to. The helper takes
  messages from the app alone, which macOS checks by the app's signature, and the app talks only
  to a run tool of its own developer.
- `proxmox-backup-client`, in the app twice: `Contents/Helpers/proxmox-backup-client` does
  every backup, listing and restore and loads only libraries macOS ships;
  `Contents/Helpers/proxmox-backup-client-mount` is the same program for Open in Finder, the
  only one that may load FUSE-T's library. The run tool hands the client the key on standard
  input and the token on a descriptor of its own, so neither shows in its arguments or its
  environment, and a release build first checks that it is the client the app's developer
  signed.

## Files

| Path | What |
|---|---|
| `~/Library/Application Support/pbs-mackup/config.json` | repository, namespace, backup id, folders, exclusions |
| `~/Library/Application Support/pbs-mackup/state.json` | what happened and what is happening, see below |
| `~/Library/Application Support/pbs-mackup/paused` | an empty file that is there while automatic backups are paused; the app makes and removes it, the run tool only looks for it |
| `~/Library/Application Support/pbs-mackup/logs/` | one log per run, kept for 30 days |
| `~/Library/Caches/pbs-mackup/` | the run lock, the backups opened in Finder (`browse`), the files opened from a backup to look at (`preview`, removed when the Backups window closes and when the app quits or starts), the names in the snapshots that were searched (`index`, removed two weeks after the last use), the last measurement of each backed-up folder (`sizes`, folder names and sizes), and during a run the list of changed folders (`changed-folders`) and a marker file for the change log (`changes`) |
| `~/Library/Group Containers/<Team ID>.<bundle identifier>/` | what no other program is to read or write. macOS asks the owner before it lets a program of another developer into this folder. `mnt` is where a run mounts its APFS snapshot, with its copy of Mail, Messages and the like; `check-…` holds the files a run restores to compare them, `key-…` a new key on its way into the Keychain, both only for a moment. `seal.json` is what the app and the run tool last stored themselves, as two digests: of the configuration and of the encryption key. An app built without a developer's identity has no such folder: it keeps the seal with `config.json` and the rest in the cache, where they are open to every program of the user |
| login Keychain, service `<bundle identifier>.tool` | the API token secret (`token`) and the encryption key (`encryption-key`). The Keychain hands them to the run tool, which signs under that name. Versions before 0.2 kept them under the bundle identifier itself; 0.2 moves them when the app first starts, and macOS asks for the login password for each |

`config.json`:

```json
{
  "repository": "user@realm!token@host:datastore",
  "namespace": "mac",
  "backupID": "my-mac",
  "sources": ["/Users/me/Documents"],
  "excludes": ["*.tmp", "node_modules", "/Movies/Raw"],
  "intervalMinutes": 30,
  "frozenSnapshot": "whenPermitted"
}
```

Each folder in `sources` becomes one archive named after it, with everything but ASCII
letters, digits, `-` and `_` turned into `_` (`.ssh` becomes `_ssh.pxar`). A folder on another
disk, or one whose archive name is already taken, can't be added. `excludes` are the owner's own
patterns, as in `.pxarexclude`. Always left out as well: `.DS_Store`, `.Trash`, `.Trashes`,
`.TemporaryItems`, `.Spotlight-V100`, `.fseventsd`, `.DocumentRevisions-V100`, a home folder's
`Library/Caches`, anything excluded from Time Machine, and files whose contents are only in
iCloud, and socket files. `backupID` takes letters, digits, `.`, `_` and `-`, and does not
begin with `.` or `-`. `intervalMinutes` is how often a backup is made; an hour when absent.

A rule, and a path given to `pbs-mackup-run`, is compared with the names in a backup byte for
byte. An accent typed on the keyboard is one character with its letter; a name made in Finder
has it as a character of its own. Rules made in the settings window and paths taken from `list`
are right either way.

A run goes only by a configuration the app or the run tool saved; it knows it by the digest in
`seal.json`, which is taken of what the file says, not of how it is written. After editing
`config.json` by hand, `pbs-mackup-run seal` (which asks for Touch ID or the login password)
or Done in the settings window makes the file the one to go by. Until then every run fails at
step `setup` and says that the settings were changed outside the app. The same goes for the
key: a key in the Keychain that the app did not put there is not used.

`sampleFiles` (20 when absent, 0 for none) is how many files are restored and compared after
each backup. The files are picked from what the exclusions leave in the backup. A picked file
that the snapshot does not have fails the run at step `verify`. It is passed over instead when
one of the exclusions is written with `**`, `[…]`, `./`, `//` or `..`, which the check cannot
judge exactly, when a folder above the file has a `.pxarexclude` file, or when the live folders
were read and the file arrived after the run began.

The secrets are stored with `pbs-mackup-run set-token` and `pbs-mackup-run set-key`, each
reading standard input and each asking for Touch ID or the login password first. `set-key`
refuses a key file that is locked with a passphrase.

## How sizes are measured

The sizes come from `pbs-mackup-run sizes <folder>`, which reads the size of every file once
(65 s for a home folder with 2.4 million files) and keeps the result in the cache; the window
opens with the last measurement and measures again when that is older than a day. Sizes are
what the files take on disk, as Finder and `du` count them. Three things make the amount to
back up smaller than the folder:

- what is always left out (see `excludes` above), shown grey in the list;
- copies that share their storage with the original (APFS clones): they are read in full but
  the server stores such data once, so the header names their share;
- files that are only in iCloud, which take no room on disk and are not backed up.

Mounted volumes inside a backed-up folder are not counted and not backed up.

## The run tool

`/Applications/PBSMackup.app/Contents/MacOS/pbs-mackup-run`, from a terminal:

```sh
pbs-mackup-run snapshots
pbs-mackup-run list <snapshot> me.pxar [<folder>]
pbs-mackup-run versions me.pxar <path>
pbs-mackup-run restore <snapshot> me.pxar <path> <target folder> [keep-both|replace|skip]
pbs-mackup-run index <snapshot> me.pxar
pbs-mackup-run mount <snapshot> me.pxar
pbs-mackup-run unmount
pbs-mackup-run sizes <folder>
```

Started this way, and not by the app, the tool asks for Touch ID or the login password before
it does any of these but `unmount` and `sizes`: any program of yours can start it, and it is
the one the Keychain hands the token and the key to.

`index` writes the names in a snapshot to a JSON file in the cache, `mount` needs FUSE-T and
prints the folder; it refuses when `/usr/local/lib/libfuse3.4.dylib`, `/usr/local/bin/go-nfsv4`
or a folder on the way to them does not belong to root or can be written by others. `unmount`
takes everything mounted this way. A snapshot is named
`host/<id>/2026-11-12T08:00:00Z` and an archive `<folder>.pxar`; anything else is refused.

Without an argument it does one scheduled run, `--manual` one that ignores the interval and
the battery, `--full` one that also reads every folder. `status` prints the state file (not
whether backups are paused: that is the file `paused`), `set-token` and `set-key` store a
secret from standard input in the Keychain.

`accept` reads `{"config": {…}, "token": "…"}` from standard input (the configuration as in
`config.json`; `token` only for a new one), asks the server, and stores both only when the
server accepts them. The settings window saves through it.

`export-key <file>` writes the recovery copy of the key, readable by you only, and `paper-key`
prints it as text; both ask for Touch ID or the login password first, also when the app asks for
them, and so do `create-key --replace` and a `set-key` that replaces a key. `seal` makes a
`config.json` that was edited by hand the one to go by. `migrate` moves the token and the key
that a version before 0.2 stored; the app asks for it when it starts. `serve` is the helper job:
it answers the app until launchd stops it. `certificate <host> <port>` prints the server
certificate's fingerprint and whether the client takes it without one, judged by the roots in
`/etc/ssl/cert.pem`. Called with a command it doesn't know, the tool lists all of them.

## When a run reads everything

A run notes where the macOS change log (FSEvents) stands before it takes its snapshot. The
next run reads the folders changed since and takes the others over from the previous backup.
A folder that was moved or renamed is read with everything below it. Everything is read when:

- there is no earlier backup to build on, or the newest one on the server isn't the one the
  last run made;
- the folders, the exclusions or the client changed;
- the last backup failed its sample check, or the last successful run could not note where the
  change log stood;
- macOS started the log over, or reports a gap or lost events;
- the log doesn't answer within two minutes;
- the run was started with `--full`.

## State file

`pbs-mackup-run` rewrites `state.json` atomically and is the only one to write it; the app
watches the folder and reads the file whenever it was replaced. Dates are ISO 8601 in UTC. Absent fields mean "not known" or "not the case".

| Field | Meaning |
|---|---|
| `version` | `1` |
| `paused` | no longer used and always `false`: whether automatic backups are paused is the file `paused` next to the state file. A `true` left by an earlier version is moved there by the next run |
| `running` | present while a run is active, see below |
| `localSnapshot` | date of the APFS snapshot the active run took, written before it is mounted so that the next run can remove it after a crash |
| `last` | the record of the most recent run. A scheduled run that is skipped for the same reason as the record before it leaves no record of its own |
| `lastSuccess` | the record of the most recent successful run |
| `consecutiveFailures` | failed runs since the last success; skipped and cancelled runs neither count nor reset it |
| `changeBase` | what the next run needs to read only what changed: `position` (the change log's `event` number and the `log` it belongs to, noted before the last successful run took its snapshot), `snapshot` (the backup that run made) and `settings` (a digest of folders, exclusions and client). Absent after a run that failed its sample check and after one that could not note a position: the next run reads everything |
| `history` | the last 100 records, oldest first |

`running`:

| Field | Meaning |
|---|---|
| `pid` | the run tool; the app shows the run and cancels it (SIGTERM) only while that process is `pbs-mackup-run` and no younger than `start` |
| `clientPID` | the client it started; a later run stops it if the run tool died |
| `start`, `trigger` | when it started and whether `scheduled` or `manual` |
| `progress.step` | `preparing`, `backing up`, `checking` or `cleaning up` |
| `progress.entries`, `bytesProcessed`, `bytesUploaded` | counts so far |
| `progress.expectedBytes` | what the last successful run processed; absent on a first run |
| `progress.path` | the entry being read, relative to its folder |
| `progress.processed`, `uploaded`, `elapsed` | the same amounts as text |
| `progress.speed`, `bitsPerSecond` | the upload speed over the last ten seconds, as text (`0.85 Gbit/s`, below a tenth of a gigabit `42 Mbit/s`) and as a number; counted from what goes over the network after compression; absent while next to nothing is sent |
| `progress.updated` | when the progress was last written |

A run record (`last`, `lastSuccess`, `history`):

| Field | Meaning |
|---|---|
| `start`, `end`, `trigger` | as above |
| `outcome` | `success`, `skipped`, `cancelled` or `failed` |
| `reason` | why it was skipped or failed, in words |
| `step` | for a failure: `setup` (no token or key, or settings or a key that the app did not store), `snapshot`, `backup` or `verify` |
| `snapshot` | the snapshot on the server, e.g. `host/my-mac/2026-11-12T08:00:00Z` |
| `frozen` | false when the live folders were read because the snapshot could not be mounted |
| `checkedFiles` | how many files were restored from the new snapshot and compared after the upload |
| `mismatches` | the ones that differed, each with what differed; the run is then `failed` at step `verify` |
| `changes` | how the run found what to read: how many changed folders it read, or why it read everything |
| `log` | path of the run's log |
| `result.entries`, `bytesProcessed`, `bytesReused`, `bytesUploaded` | totals from the client |
| `result.totalFiles`, `unchangedFiles`, `changedFiles` | from the client's change detection |
| `result.archives` | per archive: `name`, `total`, `uploaded`, `reused`, as the client prints them |
| `result.skippedPlaceholders`, `skippedPlaceholderCount` | files whose contents are not on disk (iCloud); at most 1000 are named |
| `result.timeMachineExcluded` | entries left out because they are excluded from Time Machine |
| `result.carriedFolders`, `readFolders`, `changeList` | folders taken over from the previous backup without being read, folders read, and whether the client used the list of changes (`used`, or `ignored: <reason>`) |
| `result.warnings`, `error`, `clientDuration` | from the client |
