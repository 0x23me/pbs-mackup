# Getting things back

The Backups window has snapshots on the left and folders on the right. Restore an item to a
folder you pick or to where it was; if something is already there you are asked first.
Right-click a file for its versions. Command-F searches the names of the whole snapshot.

## After losing the Mac

The whole home folder comes back on a freshly installed Mac, and you log in to it as before:
files, settings, the login keychain, and PBS Mackup with its settings.

1. Install macOS. In Setup Assistant, make your account with the same short name as before
   (`me`) and your old password, which the old login keychain opens with.
2. Install PBS Mackup and choose **Restore from a Backup…** in its menu. Turn on Full Disk
   Access and allow the restore helper, as the window asks; enter the server, the token and
   the recovery copy of the key.
3. **Find Backups** has an administrator allow the restore and picks the newest snapshot;
   **Restore…** starts it. You can keep working meanwhile, but what you save in this account
   until you log out is set aside.
4. When it says so, log out and log in again. The restored home folder is in place, and PBS
   Mackup stores the token and the key you entered in step 2 again: the Keychain they were in
   only opens on the old Mac. **Finish** deletes the folder from before and removes the helper,
   and backups go on.

If the Mac restarts between the restore and logging in again, the token and the key are gone
with the helper's memory. The window says so: enter the token in Settings and import the
recovery copy of the key.

The restore helper is the part of PBS Mackup that runs as root. It is only registered while you
restore, takes messages from the app alone, and does nothing without an administrator's password
or Touch ID. It restores inside a folder that only root can open, `/Users/.pbs-mackup-restore-me`,
and deletes nothing in a folder of yours: the home folder from before, which waits as
`/Users/me.before-restore` until you finish, is deleted by the app, as you. What you may not
delete there stays, and Finish says so. From a terminal, the same works with `sudo pbs-mackup-run restore-home me
'mac@pbs!backup@pbs.example.net:store' key.json --ns mac`, run from another administrator's
account while `me` is logged out. That way the token and the key are not stored for you: root
can't reach your Keychain. Enter the token in Settings and import the recovery copy after you
log in.

With [Mac Settings](#mac-settings-beta) switched on, the app then offers to add your login items back.

Not in the backup and so not back: the apps (install them again), Full Disk Access and the other
permissions in Privacy & Security, background items apps register themselves (they come back
when you open the app), what is excluded from Time Machine, caches, and keychain items
that belong to the old Mac's hardware. iCloud Drive and other cloud storage are left out of the
restore; they sync again once you sign in. PBS Mackup's next run reads everything.

## Mac Settings (beta)

Your files are the backup. Some of a Mac's settings live outside the home folder, though, and a
restore of the files doesn't bring them back. **Mac Settings** records them with each backup. It
is a beta feature, off unless you switch it on under **Beta Features** in the settings; backing up and
restoring files works the same either way. So far it covers one thing: the apps in your "Open
at Login" list (System Settings > General > Login Items).

Choose a snapshot in the Backups window and click **Mac Settings…** to see them. An app that's installed is added back with **Add**, or all
of them with **Add All**; one that isn't says "install first", and becomes addable as soon as
you install it. After a home restore the app offers this once by itself. Whether an app opened
hidden isn't recorded: macOS ignores that setting.

Reading and adding login items goes through System Events, which macOS lets the app control
only once you agree. Allow it under **Record login items** in the Beta Features tab. Without it, backups go on without the list, and the screen says so.

## Without the Mac

On Linux, with the official `proxmox-backup-client` 4.x and the recovery copy of the key:

```sh
export PBS_REPOSITORY='mac@pbs!backup@pbs.example.net:store'
proxmox-backup-client snapshot list --ns mac
proxmox-backup-client restore host/my-mac/2026-11-12T08:00:00Z me.pxar /restore/target \
  --ns mac --keyfile key.json --ignore-xattrs true
```

With Mac Settings on, the recorded login items of a snapshot are in a small blob of their own:

```sh
proxmox-backup-client restore host/my-mac/2026-11-12T08:00:00Z settings.conf - \
  --ns mac --keyfile key.json
```

You get contents, names, permissions, dates and links, not the Mac-only metadata.
`--ignore-xattrs true` is needed because that metadata is stored in extended attributes
Linux refuses on symlinks.
