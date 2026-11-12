# Reference

What the app keeps where, and the files it reads and writes. The [README](../README.md) is
the place to start.

## The parts

- `PBSMackup.app`: the menu bar app. Shows the state, starts and cancels backups, browses
  snapshots and restores items. It registers the launchd job.
- `pbs-mackup-run`, in the app: performs one backup run and exits. launchd starts it every five
  minutes and it runs when the interval from the settings is over. The app asks it for
  everything that needs the token or the key, so the app itself never reads them.
- `proxmox-backup-client`, in the app: the macOS client.

## Files

| Path | What |
|---|---|
| `~/Library/Application Support/pbs-mackup/config.json` | repository, namespace, backup id, folders, exclusions |
| `~/Library/Application Support/pbs-mackup/state.json` | what happened and what is happening, see below |
| `~/Library/Application Support/pbs-mackup/logs/` | one log per run, kept for 30 days |
| `~/Library/Caches/pbs-mackup/` | the run lock, the mount point of the APFS snapshot (`mnt`), the backups opened in Finder (`browse`), the names in the snapshots that were searched (`index`, removed two weeks after the last use), the last measurement of each backed-up folder (`sizes`, folder names and sizes), and during a run the list of changed folders (`changed-folders`) and a marker file for the change log (`changes`) |
| login Keychain, service named after the app's bundle identifier | the API token secret (`token`) and the encryption key (`encryption-key`) |

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

Each folder in `sources` becomes one archive named after it. `excludes` are the owner's own
patterns, as in `.pxarexclude`. Always left out as well: `.DS_Store`, `.Trash`, `.Trashes`,
`.TemporaryItems`, `.Spotlight-V100`, `.fseventsd`, `.DocumentRevisions-V100`, a home folder's
`Library/Caches`, anything excluded from Time Machine, and files whose contents are only in
iCloud. `intervalMinutes` is how often a backup is made; an hour when absent. `sampleFiles` (20 when absent, 0 for none) is how many files are restored and compared
after each backup. The secrets are stored with
`pbs-mackup-run set-token` and `pbs-mackup-run set-key`, each reading standard input.

## How sizes are measured

The sizes come from `pbs-mackup-run sizes <folder>`, which reads the size of every file once
(65 s for a home folder with 2.4 million files) and keeps the result in the cache; the window
opens with the last measurement and measures again when that is older than a day. Sizes are
what the files take on disk, as Finder and `du` count them. Three things make the amount to
back up smaller than the folder:

- what is always left out (see `excludes` below), shown grey in the list;
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
pbs-mackup-run index <snapshot> me.pxar      # the names in the snapshot as a JSON file in the cache; prints the file
pbs-mackup-run mount <snapshot> me.pxar      # prints the folder; needs FUSE-T
pbs-mackup-run unmount                              # everything mounted this way
pbs-mackup-run sizes <folder>                       # measure a folder for the settings; prints the file
```

Without an argument it does one scheduled run, `--manual` one that ignores the interval and
the battery, `--full` one that also reads every folder. `status` prints the state file,
`set-token` and `set-key` store a secret from standard input in the Keychain.

## State file

`pbs-mackup-run` rewrites `state.json` atomically; the app reads it once a second and only ever
changes `paused`. Dates are ISO 8601 in UTC. Absent fields mean "not known" or "not the case".

| Field | Meaning |
|---|---|
| `version` | `1` |
| `paused` | scheduled runs do nothing while true; a run started by hand still runs |
| `running` | present while a run is active, see below |
| `localSnapshot` | date of the APFS snapshot the active run took, written before it is mounted so that the next run can remove it after a crash |
| `last` | the record of the most recent run |
| `lastSuccess` | the record of the most recent successful run |
| `consecutiveFailures` | failed runs since the last success; skipped and cancelled runs neither count nor reset it |
| `changeBase` | what the next run needs to read only what changed: `position` (the change log's `event` number and the `log` it belongs to, noted before the last successful run took its snapshot), `snapshot` (the backup that run made) and `settings` (a digest of folders, exclusions and client) |
| `history` | the last 100 records, oldest first |

`running`:

| Field | Meaning |
|---|---|
| `pid` | the run tool; the app cancels by sending it SIGTERM |
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
| `step` | for a failure: `setup`, `snapshot`, `backup` or `verify` |
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

From the terminal, with the run tool in the app bundle:

```sh
pbs-mackup-run snapshots
pbs-mackup-run list <snapshot> Downloads.pxar [<folder>]
pbs-mackup-run versions Downloads.pxar <path>
pbs-mackup-run restore <snapshot> Downloads.pxar <path> <target folder> [keep-both|replace|skip]
pbs-mackup-run index <snapshot> Downloads.pxar      # the names in the snapshot as a JSON file in the cache; prints the file
pbs-mackup-run mount <snapshot> Downloads.pxar      # prints the folder; needs FUSE-T
pbs-mackup-run unmount                              # everything mounted this way
pbs-mackup-run sizes <folder>                       # measure a folder for the settings; prints the file
```
