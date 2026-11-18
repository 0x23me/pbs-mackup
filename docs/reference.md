# Reference

What the app keeps where, and the files it reads and writes. The [README](../README.md) is
the place to start.

## The parts

- `PBSMackup.app`: the menu bar app. Shows the state, starts and cancels backups, browses
  snapshots and restores items. It registers the launchd job.
- `pbs-mackup-run`, in the app (in a bundle of its own there, `Contents/Helpers/PBSMackupRun.app`,
  with `Contents/MacOS/pbs-mackup-run` as a link to it): performs one backup run and exits. launchd starts it every five
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
- `proxmox-backup-client`, in `Contents/Helpers`: does every backup, listing and restore and
  loads only libraries macOS ships. The run tool hands the client the key on standard
  input and the token on a descriptor of its own, so neither shows in its arguments or its
  environment, and a release build first checks that it is the client the app's developer
  signed: the file before it starts it, and the started program before that runs. The client
  starts suspended for this, whether it is to back up, to make a key or to unlock one, and one
  that does not pass is stopped without having run. The client's home folder is not yours but
  one of its own, `client` in the group container (see below). What it reads from
  `.config/proxmox-backup` in its home would otherwise be for any program of yours to write: a
  `master-public.pem` there makes every backup upload its encryption key, encrypted for
  whoever has the other half; a line in `fingerprints` makes the client accept a certificate
  it would turn away; an `encryption-key.json` is the key of a command that was given none.
  A file of that kind in your own home folder, left by a `proxmox-backup-client` you used
  yourself, is not read by the app.

## Files

| Path | What |
|---|---|
| `~/Library/Application Support/pbs-mackup/config.json` | repository, namespace, backup id, folders, exclusions |
| `~/Library/Application Support/pbs-mackup/state.json` | what happened and what is happening, see below |
| `~/Library/Application Support/pbs-mackup/paused` | an empty file that is there while automatic backups are paused; the app makes and removes it, the run tool only looks for it |
| `~/Library/Application Support/pbs-mackup/logs/` | one log per run, kept for 30 days |
| `~/Library/Caches/pbs-mackup/` | the run lock, the files opened from a backup to look at (`preview`, removed when the Backups window closes and when the app quits or starts), and during a run a marker file for the change log (`changes`, an empty file). Versions up to 0.5.0 also kept `index`, `sizes`, `changed-folders` and `settings.json` here; the next run removes them |
| `~/Library/Group Containers/<Team ID>.<bundle identifier>/` | what no other program is to read or write. macOS asks the owner before it lets a program of another developer into this folder. `mnt` is where a run mounts its APFS snapshot, with its copy of Mail, Messages and the like; `check-…` holds the files a run restores to compare them, `key-…` a new or imported key on its way into the Keychain, both only for a moment: whoever makes such a folder holds a lock on it (`flock`) while it uses it, and one that a killed command or a power cut left behind, its lock free, is removed by the next run and when the helper next starts. `client` is the home folder the client is given, with `.config` and `.cache` in it, each for the owner alone (mode 700); the client notes the repositories it was used with there (`.cache/proxmox-backup/repo-list`), and the app puts nothing into it. What names the owner's files is here too: the names in the snapshots that were searched (`index`, removed two weeks after the last use), the last measurement of each backed-up folder (`sizes`, folder names and sizes), both marked as left out of backups the way an app marks a folder for Time Machine, and during a run the list of changed folders (`changed-folders`) and the settings manifest (`settings.json`, see below). `seal.json` is what the app and the run tool last stored themselves, as two digests: of the configuration and of the encryption key. An app built without a developer's identity has no such folder: it keeps the seal with `config.json` and the rest in the cache, where they are open to every program of the user |
| data protection keychain, access group `<Team ID>.<bundle identifier>`, service `<bundle identifier>.tool` | the API token secret (`token`) and the encryption key (`encryption-key`), for this Mac alone, readable once the Mac was unlocked after it started. macOS lets only a program in that access group read, make, replace or delete these items, and a program is in it only by a provisioning profile of the developer: the run tool is, and nothing else, not the app and not the client. Versions 0.2 to 0.5 kept the items in the login keychain under the same service. The run tool takes them over from there the first time it needs one and finds none of its own, and removes them there, so the run tools of those versions find nothing. The key is taken over only when it is the one in `seal.json`; any other key stays where it is and is not used, and Settings asks for the recovery copy. The token is taken over as it is. An item there that macOS would ask you about is another program's and is left alone |
| login keychain, service `<bundle identifier>.tool` | the same two items in an app built without a provisioning profile for the run tool (see [building](building.md)), and up to 0.5.0. This keychain hands an item to the program that stored it, and lets any program delete an item and make one under the same name. So a secret is stored by removing the item and making it anew, never by changing it, so that an item another program made first under this name, to read what is stored in it, goes away with that. Where the run tool cannot remove such an item, nothing is stored and the error says which item to delete. Versions before 0.2 kept the items under the bundle identifier itself; nothing is taken over from there |

`config.json`:

```json
{
  "repository": "user@realm!token@host:datastore",
  "namespace": "mac",
  "backupID": "my-mac",
  "sources": ["/Users/me/Documents"],
  "excludes": ["*.tmp", "node_modules", "/Movies/Raw"],
  "intervalMinutes": 30,
  "frozenSnapshot": "whenPermitted",
  "macSettings": true
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
refuses a key file that is locked with a passphrase; `unlock-key` takes it, as
`{"key": "…", "passphrase": "…"}` on standard input with the text of the key file or of the paper
key. The client's `key change-passphrase --kdf none` takes the passphrase off, in a `key-…`
folder that is removed right after (or, when the command is killed, by the next run), and the
key is stored without it. The client gets the
passphrase on a descriptor of its own (`PBS_ENCRYPTION_PASSWORD_FD`), never in its arguments or
environment. The settings window asks for the passphrase when the chosen file has one.

## How sizes are measured

The sizes come from `pbs-mackup-run sizes <folder>`, which reads the size of every file once
(65 s for a home folder with 2.4 million files) and keeps the result in `sizes` (see Files); the window
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
pbs-mackup-run sizes <folder>
pbs-mackup-run settings <snapshot>
```

Started this way, and not by the app, the tool asks for Touch ID or the login password before
it does any of these: any program of yours can start it, and it is
the one the Keychain hands the token and the key to. `sizes` asks as well: with Full Disk
Access the tool reads the names in any folder.

Each command says in the tool's list (`commands` in `Sources/RunTool/main.swift`) who may ask
for it, and anyone else is refused before anything is done: the app over the helper's
connection, a program started as you (a terminal, a launchd job), or root. The app gets what
its windows ask for: these seven, `accept`, `setup-status`, the commands for the key, and
`set-token`, which it uses only after a restore of the home folder (see below). A run, `serve`,
`status`, `check`, `seal` and `certificate` are only started as a program, and `restore-home`
and `restore-daemon` only as root, which the others refuse.

`settings` prints the settings manifest of a snapshot (see below). `index` writes the names in a snapshot to a JSON file in `index` (see Files). A snapshot is named
`host/<id>/2026-11-12T08:00:00Z` and an archive `<folder>.pxar`; anything else is refused.

Without an argument it does one scheduled run, `--manual` one that ignores the interval and
the battery, `--full` one that also reads every folder. `status` prints the state file (not
whether backups are paused: that is the file `paused`), `set-token`, `set-key` and `unlock-key`
store a secret from standard input in the Keychain.

`accept` reads `{"config": {…}, "token": "…"}` from standard input (the configuration as in
`config.json`; `token` only for a new one), asks the server, and stores both only when the
server accepts them. The settings window saves through it.

`export-key <file>` writes the recovery copy of the key, readable by you only, and `paper-key`
prints it as text; both ask for Touch ID or the login password first, also when the app asks for
them, and so do `create-key --replace` and a `set-key` or `unlock-key` that replaces a key. `seal` makes a
`config.json` that was edited by hand the one to go by, also when no configuration is noted
at all (the seal is gone, say): nothing notes a configuration or a key by itself just because
it is there. For the key it is `set-key` or `unlock-key` with the recovery copy. `serve` is the helper job:
it answers the app until launchd stops it. `certificate <host> <port>` prints the server
certificate's fingerprint and whether the client takes it without one, judged by the roots in
`/etc/ssl/cert.pem`. Called with a command it doesn't know, the tool lists all of them.

## The settings manifest

While Mac Settings is switched on (a beta feature; `"macSettings": true` in `config.json`, absent when
off), each run records the settings that live outside the backed-up folders and uploads them with the
backup as `settings.conf` (on the server `settings.conf.blob`), encrypted with the same key.
It doesn't count as an archive: the Backups window, search and `restore-home` don't show it.
Snapshots from before this was added don't have one. Fetched by itself:

```sh
proxmox-backup-client restore host/my-mac/2026-11-12T08:00:00Z settings.conf - --ns mac --keyfile key.json
```

```json
{
  "format": 1,
  "taken": "2026-11-16T09:00:00Z",
  "macOS": "27.2",
  "loginItems": {
    "status": "ok",
    "items": [ { "name": "Raycast", "bundleID": "com.raycast.macos", "path": "/Applications/Raycast.app" } ]
  }
}
```

Each kind of setting is a section with `status` (`ok` or `unavailable`), a `reason` when it is
unavailable, and `items`. A reader ignores sections it doesn't know; `format` changes only when
a section changes incompatibly. Login items are the only section so far. They're read from
System Events, with the Automation permission the app asks for under **Record login items** in the Beta Features tab. A
run only checks that permission and never asks for it. Without it, or when System Events takes
more than 5 seconds, the section is `unavailable` with the reason, and the backup goes on.
`bundleID` comes from the app at `path` and is missing where that has none. On a restored Mac,
the app finds an app by its bundle identifier first and by its path second.

## Restoring a whole home folder

```sh
sudo pbs-mackup-run restore-home <user> <repository> <key file> [--ns <namespace>]
    [--from <backup id> | --snapshot <snapshot>] [--archive <folder>.pxar] [--fingerprint <fingerprint>] [--yes]
```

For a Mac that was set up anew; the steps around it are in the README ("After losing the Mac").
It runs as root and only from a terminal, never for the app, and takes nothing from a Keychain:
the token secret is asked for (or read from standard input when that is not a terminal), the
key comes from the recovery file, and a key file locked with a passphrase asks for it. The
client gets all three on descriptors, as in a backup. Nothing stores them for the user
afterwards: root cannot reach the user's Keychain. The user enters the token in Settings and
imports the recovery copy. A backup made without a provisioning profile for the run tool, or by
0.5 or earlier, has them in the login keychain, which comes back with the home folder.

It refuses when the user does not exist, has programs running (logged in, also when the Mac only
switched to another user) or is the one who started `sudo`, when a restore that did not finish
or `<home>.before-restore` is already there, and when the disk has less room than the snapshot
takes. The archive is the one named after the user's home folder (`me.pxar`), and the snapshot
the newest that has it, of the one backup group that has it; with two such groups `--from` says
which. Then, after a question that `--yes` answers:

1. The archive is restored as `/Users/.pbs-mackup-restore-<name>/<name>`, with owners,
   permissions, ACLs, flags and the Mac metadata. A restore that fails leaves nothing behind.
2. When the restored folder belongs to another uid than the user has on this Mac, everything of
   that uid becomes the user's.
3. macOS names a user in an ACL by a GeneratedUID, which a new account gets anew. When the ACLs
   name exactly one id this Mac does not know, that is the owner as the old Mac knew them, and
   it is replaced with the user's id here. By default only `Public/Drop Box` has such an ACL.
4. The cloud folders are taken out (`Library/Mobile Documents`, `Library/CloudStorage`, iCloud
   Drive's file provider and its state); their contents come back from the cloud.
5. The home folder becomes `<home>.before-restore` and the restored one takes its place. When
   the second step fails the first is undone. Moving a home folder needs Full Disk Access for
   the terminal. `.pbs-mackup-restore-<name>` is empty then and removed.

### Where root works

A restored folder belongs to its user from the first file on, and the user can log in while
root still works in it. Whoever owns a folder can put a link where root is about to go by path,
which sends root's change of an owner, or its delete, to any file on the Mac. So:

- The restore happens in `/Users/.pbs-mackup-restore-<name>`: root's, mode 700, no ACL, on the
  volume of the home folder so that the swap is a rename. One that is already there is used
  only when it is exactly that; anything else is refused and left alone. Nobody but root gets
  at the restored folder before it is the home folder.
- Below the restored folder root uses no paths. Each folder is opened from the one above it
  and never through a link, the volume is not left, and owners, flags and ACLs are changed on
  a descriptor of the item itself, after checking that it is the item that was looked at. A
  link has such a descriptor too, of its own. Sockets, pipes and devices have none: their
  owner changes by their name in the open folder, and their ACLs are left as they are.
- Root deletes only inside `.pbs-mackup-restore-<name>`: the cloud folders, and a restore that
  failed or was cancelled. The home folder that is set aside is its owner's, who can reach it;
  root removes it only once it is empty (see below), and `restore-home` leaves it for an
  administrator to delete.

### From the app

**Restore from a Backup…** does the same for the user who is logged in, without a second
administrator. Its root part is the run tool as the launchd daemon `<bundle identifier>.restore`
(`pbs-mackup-run restore-daemon`), which the app registers with `SMAppService` when the window
needs it and unregisters at Finish; macOS asks the owner to allow it under Login Items.

- It answers only the app, checked by the code signature of the connection.
- Every message carries the external form of an authorization for the right
  `<bundle identifier>.restore-home`, which the daemon checks without asking anyone. Its rule:
  an administrator authenticates, and that holds for five minutes in that one authorization.
  An administrator can change it with `security authorizationdb`; a rule of their own is kept.
- Token, key and passphrase arrive in the messages and go to the client on descriptors. The
  daemon keeps them in its memory, never on disk, until Finish or a failure.
- The data protection keychain lives in the home folder, in `Library/Keychains/<hardware UUID>`,
  and opens only on the Mac that made it. So the one that holds the token and the key goes with
  the home folder that is set aside, and the restored one has none this Mac can open. After the
  swap, when the user logs in, the app opens the restore window and first asks the daemon for
  the token, the key and its passphrase. The daemon gives them only to the app (by its
  signature), only to the user whose home folder it restored, and only between the swap and
  Finish; no administrator is asked, since it hands back what the app sent. The app has the run
  tool store them, as the user: the token with `set-token`, and the key with `set-key` or
  `unlock-key` when the Keychain has none, or one the app did not put there (which asks for
  Touch ID or the password). A key the app put there stays: it is the key the backups were made
  with. Storing the key notes it in the restored `seal.json`; the configuration's seal comes back
  with the home folder. When the Mac restarted between the restore and the login, the daemon has
  nothing to give: the window says so, and the user enters the token in Settings and imports
  the recovery copy, as before.
- The restore goes to `/Users/.pbs-mackup-restore-<name>/<name>`, as above; the state, without
  secrets, is in `/Library/Application Support/<bundle identifier>/restore.json`. Once the user
  has no login session left, the daemon ends what macOS keeps running for them (their launchd
  domain, then any program still running as them) and swaps the folders. A login before that
  puts the swap off to the next logout; a restart while restoring throws the restore away.
- Cancelling, and Start Over after a failure, remove `.pbs-mackup-restore-<name>` with what is
  in it.
- Finish, after the swap, is the owner's: the daemon refuses it from another account. The app
  deletes what is in `<home>.before-restore`, as the user and with its own Full Disk Access,
  and the daemon then removes the folder itself from `/Users`, which only root can, and only
  when it is empty. What the user may not delete (a folder root made in there, say) is listed,
  and the owner chooses between trying again and finishing with the rest left in place, for an
  administrator to remove (`sudo rm -rf`). Nothing is handed to root to delete.
- Every finish also removes the state, its folder and the right from the authorization
  database, unless an administrator changed the rule. `brew uninstall --zap` removes all of
  these for an app that goes in the middle of a restore.
- A restore that 0.5.0 or earlier left waiting for the logout lies in `<home>.restored`, which
  its owner could change. This version does not put it in place: it says so, and the restore
  is started again once an administrator has removed that folder.

## When a run reads everything

A run notes where the macOS change log (FSEvents) stands before it takes its snapshot. The
next run reads the folders changed since and takes the others over from the previous backup.
A folder that was moved or renamed is read with everything below it. macOS logs a change to a
file's contents only once the program that wrote it closes it, so a run also reads the folders
of the files that the owner's programs have open for writing, or mapped to write to, after it
took its snapshot (a database that a background process keeps open, for one). What programs of
other users or of the system keep open is not known; it is in the log once they close it.
Everything is read when:

- there is no earlier backup to build on, or the newest one on the server isn't the one the
  last run made;
- the folders, the exclusions or the client changed;
- the last backup failed its sample check, or the last successful run could not note where the
  change log stood;
- macOS started the log over, or reports a gap or lost events;
- the log doesn't answer within two minutes;
- the last successful run that read everything began more than seven days ago, or none is on
  record;
- the run was started with `--full`.

Apple calls the change log advisory and recommends a full read now and then, hence the seven
days. To read everything now:

```sh
/Applications/PBSMackup.app/Contents/MacOS/pbs-mackup-run --full
```

## State file

`pbs-mackup-run` rewrites `state.json` atomically and is the only one to write it; the app
watches the folder and reads the file whenever it was replaced. Dates are ISO 8601 in UTC. Absent fields mean "not known" or "not the case".

| Field | Meaning |
|---|---|
| `version` | `1` |
| `paused` | no longer used and always `false`: whether automatic backups are paused is the file `paused` next to the state file. Nothing reads the field; it is written because the versions 0.2 to 0.5 cannot read a state file without it |
| `running` | present while a run is active, see below |
| `localSnapshot` | date of the APFS snapshot the active run took, written before it is mounted so that the next run can remove it after a crash |
| `last` | the record of the most recent run. A scheduled run that is skipped for the same reason as the record before it leaves no record of its own |
| `lastSuccess` | the record of the most recent successful run |
| `consecutiveFailures` | failed runs since the last success; skipped and cancelled runs neither count nor reset it |
| `changeBase` | what the next run needs to read only what changed: `position` (the change log's `event` number and the `log` it belongs to, noted before the last successful run took its snapshot), `snapshot` (the backup that run made) and `settings` (a digest of folders, exclusions and client). Absent after a run that failed its sample check and after one that could not note a position: the next run reads everything |
| `lastFullRead` | when the last successful run began that read everything, from the start or because the client set the list of changes aside. A run reads everything when it is more than seven days ago or absent |
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
