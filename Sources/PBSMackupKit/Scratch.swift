import Darwin
import Foundation

/// A folder of its own for what a command needs only while it works: a new or imported key on
/// its way into the Keychain (`key-…`), the files a run restores to compare them (`check-…`).
/// It lies where other developers' programs are kept out (`Paths.guarded`), as far as this
/// build has such a place, only the owner can enter it, and the command removes it when it is
/// done.
///
/// A command that is killed, or a Mac that loses power, leaves its folder behind, with an
/// unlocked key or readable copies of the owner's files in it. `removeLeftovers` removes such
/// folders, and it must not take the folder of a command that is still at work: a run holds
/// `Paths.lock`, a call that makes a key holds nothing. So whoever makes a folder here holds a
/// lock on it (`flock`) for as long as it uses it. macOS lets go of the lock when the program
/// ends, however it ends, so a folder whose lock is free is nobody's. The folder's age says
/// less: a check over a slow line takes longer than any age one would pick, and a clock can
/// be set.
public final class Scratch {
    enum Kind: String, CaseIterable { case key, check }

    let folder: URL
    /// The open folder, which is what holds the lock.
    private var descriptor: Int32

    init(_ kind: Kind) throws {
        try FileManager.default.createDirectory(at: Paths.guarded, withIntermediateDirectories: true)
        // `removeLeftovers` can come by between the making of a folder and the lock on it, and
        // take the folder away. The lock is then on a folder that is gone, and another is made.
        for _ in 0..<5 {
            let folder = Paths.guarded.appendingPathComponent("\(kind.rawValue)-\(UUID().uuidString)")
            guard mkdir(folder.path, 0o700) == 0 else { break }
            let descriptor = Scratch.open(folder)
            // On a file system without locks the folder is used without one, and stays when
            // it is left behind: `removeLeftovers` gets no lock there either.
            if descriptor >= 0 { while flock(descriptor, LOCK_EX) != 0 && errno == EINTR {} }
            var held = stat(), named = stat()
            if descriptor >= 0, fstat(descriptor, &held) == 0, lstat(folder.path, &named) == 0,
               held.st_dev == named.st_dev, held.st_ino == named.st_ino {
                self.folder = folder
                self.descriptor = descriptor
                return
            }
            if descriptor >= 0 { close(descriptor) }
        }
        throw Failure(description: "No \(kind.rawValue) folder could be made in \(Paths.guarded.path): \(String(cString: strerror(errno))).")
    }

    deinit { if descriptor >= 0 { close(descriptor) } }

    /// The folder itself, opened: not what a link of its name leads to. In a build without a
    /// guarded folder any program of the user could put one there.
    private static func open(_ folder: URL) -> Int32 {
        Darwin.open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }

    /// Removes the folder with all that is in it, and lets go of it after that. What is in it
    /// can be restored items, which do not always let themselves be deleted; see `removeRestored`.
    func remove() {
        removeRestored(folder)
        if descriptor >= 0 { close(descriptor) }
        descriptor = -1
    }

    /// Removes the folders of commands that did not get to remove their own: every one whose
    /// lock is free. One that is in use, by this program or another, stays.
    public static func removeLeftovers() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Paths.guarded.path)) ?? []
        for name in names where Kind.allCases.contains(where: { name.hasPrefix($0.rawValue + "-") }) {
            let folder = Paths.guarded.appendingPathComponent(name)
            let descriptor = open(folder)
            guard descriptor >= 0 else { continue }
            defer { close(descriptor) }
            // Held while the folder goes: a command that made this very folder a moment ago
            // waits for its own lock and then finds the folder gone.
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { continue }
            removeRestored(folder)
        }
    }
}
