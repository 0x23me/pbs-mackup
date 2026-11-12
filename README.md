# pbs-mackup

Backs up a Mac to a [Proxmox Backup Server](https://www.proxmox.com/en/products/proxmox-backup-server/overview)
the way Time Machine backs up to a disk: on its own, in the background, with an icon in the
menu bar and a window to go back in time and pull things out again.

I already had a PBS keeping history for everything else in the house, deduplicated, encrypted
and verified, and no way to put the laptop in there without losing what makes Mac files Mac
files. This is that: a menu bar app around a native macOS build of `proxmox-backup-client`.

It backs up your user folder, not the system. Getting a Mac back means: install macOS, install
this, restore your user folder. If you want a bootable clone, this is the wrong tool.

Not a Proxmox product and not supported by Proxmox. If something breaks, open an issue
[here](../../issues).

## What it does

- Reads from a frozen APFS snapshot, so a file can't change halfway through a backup.
- Encrypts on the Mac. The server stores chunks it can't read, and neither can anyone with
  the server's disks.
- Keeps Mac metadata: extended attributes, tags, Finder info, resource forks, creation dates,
  ACLs and flags. The file contents stay readable by the stock Linux client, so you are not
  locked into this app to get your data back.
- After the first run it only reads the folders macOS says have changed (the same change log
  Time Machine uses), so a run with little to do takes seconds, not a walk through two million
  files.
- Restores a handful of files from every new snapshot and compares them with the originals.
  A backup that can't be read back fails loudly instead of sitting there looking fine.
- Shows what's in your home folder largest first, so you can untick the 90 GB of virtual
  machines, and suggests the usual suspects: `node_modules`, build folders, package caches.
- Browse any snapshot, search it by name, see the versions of one file, restore to where it
  was or somewhere else. With [FUSE-T](https://www.fuse-t.org) installed, open a snapshot in
  Finder.

Left out by itself: caches, the Trash, anything an app has marked as not worth backing up
(the mark Time Machine obeys too), files that only exist in iCloud, and socket files.

## Install

Apple silicon, macOS 26 or later, and a Proxmox Backup Server 4.x to talk to.

```sh
brew tap 0x23me/tap
brew trust --cask 0x23me/tap/pbs-mackup      # Homebrew 7 wants this for casks outside its own
brew install --cask 0x23me/tap/pbs-mackup
```

Or take `PBSMackup-VERSION.zip` from [releases](../../releases), unzip it and move the app to
Applications. Signed and notarized.

## On the server

Give the Mac its own namespace and a token that can add backups there and do nothing else.
On the PBS host, with your datastore's name for `store`:

```sh
proxmox-backup-debug api create /admin/datastore/store/namespace --name mac
proxmox-backup-manager user generate-token root@pam macbackup        # prints the secret, once
proxmox-backup-manager acl update /datastore/store/mac DatastoreBackup --auth-id 'root@pam!macbackup'
```

`DatastoreBackup` lets the token write backups and read its own. It can't delete or prune, so
a Mac that gets owned can't take its history with it. Thinning out old snapshots is the
server's job:

```sh
proxmox-backup-manager prune-job create mac-retention --store store --ns mac --schedule hourly \
  --keep-hourly 24 --keep-daily 30 --keep-weekly 52
proxmox-backup-manager verify-job create mac-verify --store store --ns mac --schedule daily \
  --ignore-verified true --outdated-after 30
```

Check your existing prune jobs first. One without a namespace covers every namespace below
the root, the new one included, and will thin the Mac's history to its own settings.

A token on another user works too; that user then needs the same role on the same path.

## Setting it up

Open the app; it lives in the menu bar. Settings has three tabs.

1. **Server.** The repository as the client writes it, `root@pam!macbackup@pbs.example.net:store`,
   the namespace, a name for this Mac's backups, and the token secret. Test Connection asks
   the server. A certificate that isn't publicly trusted shows its fingerprint to compare
   with the one on the server's dashboard.
2. **Encryption Key.** Make a new key, then save the recovery file or print the paper key
   and put it somewhere that isn't this Mac. Setup doesn't finish before you have. Without
   the key or that copy nobody can read the backups, you included. On a second Mac, or this
   one after a reinstall, import the copy instead.
3. **What to Back Up.** Starts with your whole home folder. Measuring it reads the size of
   every file once, about a minute for two million files. Untick what you don't need, take
   the suggestions you agree with, or type a name (`*.iso`, left out wherever it is) or a
   path. Pick how often to back up, from every 15 minutes to once a day.

Then switch on Full Disk Access for PBS Mackup (System Settings, Privacy & Security). macOS
only lets an app mount a snapshot of the disk, and read Mail, Messages or Photos, with it.
Without it the app reads the live folders and says so.

The first backup reads everything and takes as long as your upload allows. The menu shows
how far it is and how fast it's going.

The token secret and the key live in your login Keychain. They never appear in a command
line, a log or the configuration file.

## Getting things back

The Backups window: snapshots on the left, folders on the right. Select something and choose
Restore… (into a folder you pick) or Restore to Original Location. If the item is already
there, nothing is touched before you've answered Replace, Keep Both or Skip. Double-click a
file to look at a copy. Right-click for its versions, one row per change rather than per
snapshot.

The search field (Command-F) looks through the names of the whole snapshot. Case and accents
don't matter, several words must all match, and `invpdf` finds `Invoice March.pdf`.

Open in Finder mounts the snapshot read-only. It needs FUSE-T (`brew install --cask fuse-t`),
and a mounted backup shows no Mac metadata, so restore files rather than copying them out.

### Without the Mac

On any Linux machine with the official `proxmox-backup-client` 4.x and the recovery copy of
the key:

```sh
export PBS_REPOSITORY='root@pam!macbackup@pbs.example.net:store'
proxmox-backup-client snapshot list --ns mac
proxmox-backup-client restore host/my-mac/2026-11-12T08:00:00Z me.pxar /restore/target \
  --ns mac --keyfile key.json --ignore-xattrs true
```

`--ignore-xattrs true` is needed: the Mac metadata travels in extended attributes Linux
refuses on symlinks. You get contents, names, permissions, dates and links; the Mac-only
metadata is left out. Each backed-up folder is one archive named after it.

## Reading only what changed

macOS keeps a log of what changed on a disk (FSEvents). A run notes where that log stands
before it takes its snapshot. The next run asks what changed since, reads those folders, and
takes every other folder over from the previous backup without opening it.

That means trusting the log, so the app is picky about when it does. It reads everything
when there is no earlier backup to build on, when the folders, the exclusions or the client
changed, when macOS started the log over or reports a gap or lost events, when the log
doesn't answer within two minutes, and when the newest backup on the server isn't the one
the last run made. A folder that was moved or renamed is read with everything below it.

Apple's own guide calls the log advisory and tells backup software to do a full sweep now and
then. There is no scheduled one yet. This reads everything once:

```sh
/Applications/PBSMackup.app/Contents/MacOS/pbs-mackup-run --full
```

Comparing two APFS snapshots, which Time Machine can also do, is reserved for Apple.

## Removing it

```sh
brew uninstall --cask pbs-mackup       # or quit the app and drag it to the Trash
rm -rf ~/Library/Application\ Support/pbs-mackup ~/Library/Caches/pbs-mackup
```

The key and the token stay in the login Keychain until you delete them in Keychain Access.
The backups stay on the server until you remove the namespace.

## What's inside

The app and the tool that does a backup run are in this repository. The client is built from
[0x23me/proxmox-backup-macos](https://github.com/0x23me/proxmox-backup-macos), branch
`pbs-mackup`: Adam Okoń's [macOS port](https://github.com/adamokon/proxmox-backup-macos) of the
Proxmox Backup client, plus what this app needed. That is skipping iCloud placeholders and
Time Machine exclusions, progress as JSON, listing a snapshot as JSON, mounting through
FUSE-T, and taking unchanged folders over from the previous backup. The commit the app was
built with is in [client.commit](client.commit).

Files, the configuration and the state file the app reads: [docs/reference.md](docs/reference.md).
Building it yourself: [docs/building.md](docs/building.md).

## State of things

Early. It runs on one Mac against one server, mine, and the client is an unofficial port.
Keep Time Machine on until you've restored something you care about from here. Tell me what
breaks.

## License

BSD-3-Clause for the app. The client inside is AGPL-3.0 and its source is linked above; see
[THIRD_PARTY.md](THIRD_PARTY.md).
