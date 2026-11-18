# Setting it up

The app lives in the menu bar. Settings has three tabs:

1. **Server.** Repository (`mac@pbs!backup@pbs.example.net:store`), namespace, a name
   for this Mac, the token secret. A certificate the client can't check against the roots
   macOS ships shows its fingerprint to compare with the server's. That includes one from your
   own CA, even when your Keychain trusts it. Nothing is saved until the server has accepted
   the connection.
2. **Encryption Key.** Make a key, then save the recovery file or print the paper key and keep
   it somewhere that isn't this Mac. The key is random, not a password: the app makes it and
   keeps it in your Keychain, so backups run without asking. Without the key or that copy
   nobody can read the backups, you included. After a reinstall, import the copy. Saving the recovery file, printing the
   paper key and replacing the key ask for Touch ID or your password. A key file that has a
   passphrase asks for it once; the key is then stored without it, since a backup that runs by
   itself has nobody to ask. The file keeps its passphrase.
3. **What to Back Up.** Starts with your whole home folder. Untick folders, take the
   suggestions (`node_modules`, build folders, caches), or add a name (`*.iso`) or a path.
   Pick how often to back up. A folder has to be on the Mac's own disk, and two folders of the
   same name can't both be backed up. With more than one folder, a path you untick in one is
   left out of the others too.

Then switch on Full Disk Access for PBS Mackup in System Settings. Without it the app can't
mount a snapshot of the disk and reads the live folders instead, and such a run stops when a
file changes while it is read, which in a whole home folder is likely.

The token secret and the key are kept in your Keychain; [what is protected](security.md)
says from whom.

## Coming from 0.1

Since 0.2 the token and the key are in Keychain items of their own, which the run tool of the
earlier versions cannot read. Nothing is taken over from where 0.1 kept them, because any
program can put an item there: enter the token again and import the recovery copy of your key
in Settings. Then delete the old items, which the run tool of 0.1 handed to whoever asked:

```sh
security delete-generic-password -s me.0x23.pbs-mackup -a token
security delete-generic-password -s me.0x23.pbs-mackup -a encryption-key
```

The backup job of 0.1 (`me.0x23.pbs-mackup.run`) may stay registered. launchd does not start
it any more.

## Coming from 0.2 to 0.5

Those versions kept the token and the key in the login Keychain, where a program that runs as
you could delete them or put its own in their place. Now they are in a part of the Keychain
that macOS opens to this app's run tool alone. The first backup or the first look at the
settings moves them there; there is nothing to do. An earlier version does not find them any
more: after going back to one, enter the token again and import the recovery copy of your key.

## Removing it

```sh
brew uninstall --cask pbs-mackup
rm -rf ~/Library/Application\ Support/pbs-mackup ~/Library/Caches/pbs-mackup \
  ~/Library/Group\ Containers/*.me.0x23.pbs-mackup
```

`brew uninstall --zap --cask pbs-mackup` removes these too, and what a restore of the whole home
folder left when it was not finished: the restore helper's right in the authorization database
(`me.0x23.pbs-mackup.restore-home`), its state in `/Library/Application Support/me.0x23.pbs-mackup`
and the folder it restored in, `/Users/.pbs-mackup-restore-<you>`. A restore that was finished
has removed all three itself.

The key and the token stay in the Keychain, the
backups on the server, and a home folder that a restore set aside, `/Users/<you>.before-restore`,
where it is.
