import Foundation

/// Shows one archive of a snapshot as a read-only folder, through the client's `mount` and
/// FUSE-T. An extra: browsing and restoring never depend on it.
extension Client {
    /// FUSE-T's library, by the name the client loads it under for `mount`, and the helper that
    /// library starts.
    static let fuseT = ["/usr/local/lib/libfuse3.4.dylib", "/usr/local/bin/go-nfsv4"]

    public static var canMount: Bool { FileManager.default.fileExists(atPath: fuseT[0]) }

    public static let fuseTNeeded = "Opening a backup in Finder needs FUSE-T (https://www.fuse-t.org). "
        + "Install it with “brew install --cask fuse-t” or from that page, then try again. "
        + "Browsing and restoring in the Backups window work without it."

    /// The first folder or file on the way to `path` that someone other than `owners` could put
    /// something else in the place of: one that belongs to somebody else, or that its group or
    /// everyone may write to. A symbolic link is followed, and the way it leads is looked at
    /// like the way to it. Nil when there is none. What is missing counts as safe: nobody
    /// else can make it in a folder that is.
    static func exchangeable(_ path: String, owners: Set<uid_t> = [0]) -> String? {
        var here = "/", ahead = path.split(separator: "/").map(String.init), links = 0
        while true {
            var info = stat()
            guard lstat(here, &info) == 0 else { return nil }
            if info.st_mode & S_IFMT == S_IFLNK {
                // The link itself lies in a folder that passed, so it stays what it is.
                guard links < 32, let target = try? FileManager.default.destinationOfSymbolicLink(atPath: here) else { return here }
                links += 1
                here = target.hasPrefix("/") ? "/" : (here as NSString).deletingLastPathComponent
                ahead = target.split(separator: "/").map(String.init) + ahead
            } else if !owners.contains(info.st_uid) || info.st_mode & (S_IWGRP | S_IWOTH) != 0 {
                return here
            }
            guard let name = ahead.first else { return nil }
            ahead.removeFirst()
            if name == "." { continue }
            here = name == ".." ? (here as NSString).deletingLastPathComponent : (here as NSString).appendingPathComponent(name)
        }
    }

    /// Why `mount` is refused where `item` is on the way to FUSE-T.
    static func fuseTExchangeable(_ item: String) -> String {
        "A backup is not opened in Finder on this Mac: \(item) does not belong to the system alone, so any program "
            + "of yours could put something else in its place. FUSE-T is loaded from there into a client that holds the token "
            + "and the key of your backups. Browsing and restoring in the Backups window work without it."
    }

    /// The folder an archive of a snapshot is mounted at, named so that a Finder window says what
    /// it shows: `Downloads 2026-11-12 14.00.00`.
    public static func mountFolder(snapshot: String, archive: String) -> URL {
        let time = (snapshot as NSString).lastPathComponent
            .replacingOccurrences(of: "T", with: " ").replacingOccurrences(of: "Z", with: "")
            .replacingOccurrences(of: ":", with: ".")
        return Paths.browse.appendingPathComponent("\((archive as NSString).deletingPathExtension) \(time)")
    }

    /// True when `folder` is the root of a mounted file system.
    public static func isMounted(_ folder: URL) -> Bool {
        var here = stat(), parent = stat()
        guard stat(folder.path, &here) == 0, stat(folder.deletingLastPathComponent().path, &parent) == 0 else { return false }
        return here.st_dev != parent.st_dev
    }

    /// Mounts the archive and returns its folder; one that is mounted already is returned as it is.
    public func mount(snapshot: String, archive: String) throws -> URL {
        try Client.check(snapshot: snapshot, archives: [archive])
        guard Client.canMount else { throw Failure(description: Client.fuseTNeeded) }
        // Any program of the user can ask the run tool to mount, and what is loaded for it runs
        // with the token and the key.
        if let item = Client.fuseT.lazy.compactMap({ Client.exchangeable($0) }).first {
            throw Failure(description: Client.fuseTExchangeable(item))
        }
        let folder = Client.mountFolder(snapshot: snapshot, archive: archive)
        if Client.isMounted(folder) { return folder }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Returns once the folder is mounted and leaves a client behind that ends with the unmount.
        _ = try capture(start(["mount", snapshot, archive, folder.path], executable: mountExecutable,
                              signedAs: Client.requirement(mounting: true)))
        guard Client.isMounted(folder) else { throw Failure(description: "The backup could not be mounted.") }
        return folder
    }

    /// Unmounts what `mount` mounted, all of it or one folder, and removes the emptied mount
    /// points. Returns the folders that could not be unmounted. Needs no token and no key.
    @discardableResult
    public static func unmount(_ folder: URL? = nil) -> [URL] {
        let folders = folder.map { [$0] }
            ?? ((try? FileManager.default.contentsOfDirectory(at: Paths.browse, includingPropertiesForKeys: nil)) ?? [])
        return folders.filter { folder in
            if isMounted(folder), tool("/sbin/umount", [folder.path]).status != 0 {
                // Something still has a file open. The mount is read-only, so nothing is lost.
                tool("/sbin/umount", ["-f", folder.path])
            }
            guard !isMounted(folder) else { return true }
            // Only ever an empty folder: rmdir refuses anything else.
            rmdir(folder.path)
            return false
        }
    }
}
