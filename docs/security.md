# What is protected

- From the server and the network: everything is encrypted on the Mac with a key the server
  never sees, file names included. The token can add backups and fetch this Mac's own, still
  encrypted; it can't delete or prune.
- The backups and the key, from other programs on the Mac: macOS hands the token and the key
  only to the app's run tool, and lets no other developer's program read, replace or delete
  them. The run tool takes requests only from the app, which macOS
  checks by its signature. Started by anything else, at a terminal say, it asks for Touch ID or
  your password before it lists or restores anything or changes the settings, the token or the
  key. It gives the key to nothing but the client it came with, checked by its signature too,
  and before it exports or replaces the key it asks even when it is the app that wants it.
- What is backed up and where to, from other programs: a run goes only by settings the app
  saved and by a key the app stored. It notes both in a folder where macOS asks you before it
  lets another developer's program in. When `config.json` or the key in the Keychain is not what
  was noted, nothing is backed up or read, and the menu says why. The same when nothing is
  noted, as after that folder was removed: what happens to be there is not taken over. Done in
  Settings notes the settings again, importing the recovery copy notes the key.
- The frozen snapshot, which holds a copy of Mail, Messages and everything else in your home
  folder, the files a run restores to check them, and the lists of file names that searching a
  backup and measuring a folder leave behind: all are in that same folder.
- Not from a program that runs as you and only wants to be in the way. It can pause backups
  or rewrite the state file. Backups then stop
  or fail and the menu says so; nothing gets out.
- Not what you are looking at: a file opened from the Backups window is an ordinary copy in the
  cache until the window closes.
- Not from the versions before 0.2 as long as their Keychain items exist: those handed the key
  to whoever asked. Delete those items ([coming from 0.1](setup.md#coming-from-01)). If an earlier
  version ran on a Mac you don't trust, make a new key.
- Not from anything that has Full Disk Access or is root, and not from a program you let in
  when macOS asks.
