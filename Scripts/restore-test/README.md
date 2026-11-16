# Whole home folder restore test

Question: after losing the Mac, does a clean macOS install plus a restore of the whole home
folder give back a user that works? Owners, ACLs, flags, xattrs, dates, the keychain, apps and
their data, the app itself.

`restore-check` (build: `swiftc -O restore-check.swift -o restore-check`) seeds test files,
takes a manifest of a folder (owner, mode, flags, ACL, xattrs, dates, link target and SHA-256 of
every item) and compares two manifests. Put this folder into the VMs as a UTM shared folder; it
shows up under `/Volumes/My Shared Files`.

## 1. The clean install

When the installer is done and Setup Assistant appears, shut the VM down and clone it in UTM.
The original becomes the old Mac, the clone the new one. Both start at the same clean point.

## 2. The old Mac (original VM)

1. Setup Assistant: user `test` (uid 501). No Apple Account in the first round.
2. Use it a little, so the restore has real app data to bring back:
   - a note in Notes, a bookmark in Safari, an event in Calendar, a reminder
   - a TextEdit document saved in Documents, and an unsaved one left open (its autosave lives
     in TextEdit's container)
   - another wallpaper, the Dock rearranged
   - `ssh-keygen -t ed25519` (so `~/.ssh` with its 700/600 modes exists), a line in `~/.zshrc`
3. `./restore-check seed ~`: test files in `~/RestoreTest` and the keychain item
   `pbs-mackup-restore-test`.
4. Install PBS Mackup, set it up (server, key, whole home folder), turn on Full Disk Access for it
   and for Terminal. Save the key's recovery file to the shared folder.
5. Back Up Now, wait until it is done, then right away:

   ```sh
   sudo ./restore-check manifest /Users/test before.tsv
   ```

   Note the snapshot name (`pbs-mackup-run snapshots`).

## 3. The new Mac (clone)

1. Setup Assistant: user `test`, same password. Then an admin user `admin`. For the harder case,
   a new Mac where the account has a new uid and GeneratedUID, delete `test` and make it again
   with `sysadminctl -addUser test -UID 503 -admin` (`admin` needs a secure token first:
   `sysadminctl -secureTokenOn admin ...`).
2. Install the PBS Mackup build to test. Log out `test` completely, log in as `admin`.
3. Restore, as the README says, and take the manifest before logging in:

   ```sh
   sudo pbs-mackup-run restore-home test '<repository>' key.json --ns mac --from mackup-test
   sudo ./restore-check manifest /Users/test restored.tsv
   ```

4. Restart, log in as `test`. Look at everything in "What to check", log out, log in as `admin`:

   ```sh
   sudo ./restore-check manifest /Users/test after.tsv
   ```

## 4. Compare

```sh
./restore-check compare before.tsv restored.tsv --details lost-in-restore.txt
./restore-check compare restored.tsv after.tsv --details changed-by-login.txt
```

The first is what backup and restore lose; it should come out empty apart from what is left out
by design, macOS-managed attributes and the churn of a logged-in user in `Library`. The second
is what macOS changed or threw away at the first login. `RestoreTest` should be identical in
both.

## What to check after the login

- Does the login go through, or does macOS say it cannot unlock the login keychain?
- `security find-generic-password -s pbs-mackup-restore-test -w` says `restore-me`.
- Notes, Safari, Calendar, Reminders, the TextEdit documents (the unsaved one too), wallpaper,
  Dock, `~/.ssh`, `~/.zshrc`.
- `ls -le ~` shows the `everyone deny delete` ACLs on Desktop, Documents and the rest.
- PBS Mackup: does it start with its settings and the key, and does the next backup run? (Full
  Disk Access is stored for the system, not in the home folder, so it has to be given again.)
- Errors in `restore.log`; which files the client could not write.

A second round: different password on the clone, to see what happens to the old login keychain.
A third: with an Apple Account and iCloud Drive in both, to see what iCloud does with a restored
`~/Library/Mobile Documents`.
