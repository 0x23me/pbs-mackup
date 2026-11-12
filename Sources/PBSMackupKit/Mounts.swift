import Foundation

/// Shows one archive of a snapshot as a read-only folder, through the client's `mount` and
/// FUSE-T. An extra: browsing and restoring never depend on it.
extension Client {
    /// FUSE-T's library, which the client loads for `mount`.
    public static var canMount: Bool { FileManager.default.fileExists(atPath: "/usr/local/lib/libfuse3.dylib") }

    public static let fuseTNeeded = "Opening a backup in Finder needs FUSE-T (https://www.fuse-t.org). "
        + "Install it with “brew install --cask fuse-t” or from that page, then try again. "
        + "Browsing and restoring in the Backups window work without it."

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
        guard Client.canMount else { throw Failure(description: Client.fuseTNeeded) }
        let folder = Client.mountFolder(snapshot: snapshot, archive: archive)
        if Client.isMounted(folder) { return folder }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Returns once the folder is mounted and leaves a client behind that ends with the unmount.
        _ = try capture(["mount", snapshot, archive, folder.path])
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
