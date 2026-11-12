# Third-party code

**Proxmox Backup client** (git.proxmox.com, `proxmox-backup`), AGPL-3.0-or-later, Copyright
(C) 2019-2026 Proxmox Server Solutions GmbH. PBSMackup.app carries `proxmox-backup-client` built
from [0x23me/proxmox-backup-macos](https://github.com/0x23me/proxmox-backup-macos), branch
`pbs-mackup`, at the commit in `client.commit`. That repository is Adam Okoń's
[macOS port](https://github.com/adamokon/proxmox-backup-macos) of the client with further
changes; it holds the complete source of the binary in the app, the license, and the
dependency patches the build applies. The app runs the client as a separate program and is
not derived from it.

The client is linked with **OpenSSL 3** (Apache-2.0) and **zstd** (BSD-3-Clause), both as
built by Homebrew, and with the Rust crates named in its `Cargo.lock`, each under its own
license.

**FUSE-T** (fuse-t.org) is not part of the app. When it is installed, the client loads its
library to show a snapshot in Finder.

"Proxmox" is a registered trademark of Proxmox Server Solutions GmbH. This project is not
affiliated with, endorsed or supported by Proxmox.
